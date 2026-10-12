/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Sends the PSVR2 Sense controllers to the PC every frame of a stream: buttons from GameController,
head-relative poses from ARKit accessory tracking. Clear XR's OpenXR layer on the PC presents them
to the game as Oculus Touch controllers and sends haptics back on the same channel.
clearxr-server's clearxr-layer/PROTOCOL.md specifies the packets and pose conventions.
*/

import Observation
import RealityKit

/// Marks the entity whose rendering drives `ControllerBridgeSystem`.
struct ControllerBridgeComponent: Component {}

/// Controller names and sending state for the stream controls.
@MainActor
@Observable
final class ControllerBridgeStatus {
    static let shared = ControllerBridgeStatus()

    fileprivate(set) var leftControllerName: String?
    fileprivate(set) var rightControllerName: String?
    fileprivate(set) var isSending = false
    /// The bridge channel is listed but visionOS can't open it, which happens after the app loses
    /// its connection to the streaming extension; only relaunching the app recovers.
    fileprivate(set) var isChannelUnavailable = false
}

#if !targetEnvironment(simulator)
import ARKit
import CoreHaptics
import FoveatedStreaming
import GameController
import OSLog
import QuartzCore
import Spatial

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClearXR", category: "ControllerBridge")

struct ControllerBridgeSystem: System {
    private static let query = EntityQuery(where: .has(ControllerBridgeComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        // `.rendering` updates this system on every rendered frame, so one packet goes out per frame.
        for _ in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            ControllerBridge.shared.update()
        }
    }
}

@MainActor
final class ControllerBridge {
    static let shared = ControllerBridge()

    private enum Hand: String, CaseIterable {
        case left, right
    }

    private struct HandState {
        var controller: GCController?
        var hapticEngine: CHHapticEngine?
        var hapticPlayer: CHHapticPatternPlayer?
    }

    /// Attempts per restart before a controller whose `Accessory` fails to load is left untracked.
    private static let accessoryAttempts = 3
    /// Seconds a provider may stay stopped or paused during a connected session before a restart.
    private static let stalledProviderLimit = 3
    /// The shortest vibration PSVR2 Sense plays reliably.
    private static let minimumHapticDuration: TimeInterval = 0.032
    private static let maximumHapticDuration: TimeInterval = 10
    /// Scales game amplitudes down to PSVR2 Sense's strong actuators.
    private static let hapticIntensityScale: Float = 0.25

    private var hands: [Hand: HandState] = [.left: HandState(), .right: HandState()]
    private var worldSession: ARKitSession?
    private var worldTracking: WorldTrackingProvider?
    private var accessorySession: ARKitSession?
    private var accessoryTracking: AccessoryTrackingProvider?
    private var sessionEventTasks: [Task<Void, Never>] = []
    private var accessoryEventTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// Identifies the latest accessory-tracking restart, so a slower earlier one drops its result.
    private var trackingGeneration = 0
    private var lastAccessoryRestart: TimeInterval = 0
    private var isStartingWorldTracking = false
    private var stalledSeconds = (world: 0, accessories: 0)

    private var channel: FoveatedStreamingSession.MessageChannel?
    private var hapticTask: Task<Void, Never>?
    private var isActive = false
    private var isSending = false
    private var sequence: UInt32 = 0
    private var sendFailures = 0
    private var lastChannelLookup: TimeInterval = 0
    private var failedChannelLookups = 0
    private var loggedChannels: Set<FoveatedStreamingSession.MessageChannel.ID> = []

    private var session: FoveatedStreamingSession?

    private init() {
        ControllerBridgeComponent.registerComponent()
        ControllerBridgeSystem.registerSystem()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ControllerBridge.shared.controllersChanged()
                }
            }
        }
    }

    /// Asks for accessory tracking and world sensing up front: visionOS prompts only when the app
    /// requests access, and a prompt mid-stream would appear over the game.
    static func requestAuthorization() async {
        let types = AccessoryTrackingProvider.requiredAuthorizations + WorldTrackingProvider.requiredAuthorizations
        _ = await ARKitSession().requestAuthorization(for: types)
    }

    /// Starts head and accessory tracking while the streaming immersive space is open.
    func start(session: FoveatedStreamingSession) async {
        guard !isActive else { return }
        isActive = true
        self.session = session
        refreshControllers()
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await monitorSecond()
            }
        }
        await restartWorldTracking()
        await restartAccessoryTracking()
    }

    func stop() {
        isActive = false
        stopSending()
        hapticTask?.cancel()
        hapticTask = nil
        channel = nil
        failedChannelLookups = 0
        ControllerBridgeStatus.shared.isChannelUnavailable = false
        monitorTask?.cancel()
        restartTask?.cancel()
        stopAccessoryTracking()
        stopWorldTracking()
        for hand in Hand.allCases {
            hands[hand]?.hapticEngine?.stop()
            hands[hand]?.hapticEngine = nil
        }
    }

    /// Sends one controller packet; runs once per rendered frame.
    func update() {
        guard isActive else { return }
        // A paused session stops sending, so the layer hands the controllers back to the runtime.
        guard let session, session.status == .connected else {
            stopSending()
            return
        }
        isSending = true
        ControllerBridgeStatus.shared.isSending = true
        guard hands.values.contains(where: { $0.controller != nil }), let channel = readyChannel(in: session) else {
            return
        }

        let anchors = runningAnchors()
        var packet = ControllerBridgePacket(sequence: sequence, sendTimeNs: Self.nanoseconds(CACurrentMediaTime()))
        packet.left = handBlock(.left, anchors: anchors)
        packet.right = handBlock(.right, anchors: anchors)
        do {
            try channel.sendMessage(packet.encoded())
            sequence &+= 1
        } catch {
            sendFailures += 1
        }
    }

    private func stopSending() {
        guard isSending else { return }
        isSending = false
        ControllerBridgeStatus.shared.isSending = false
        stopAllHaptics()
    }

    // MARK: - Channel

    /// The bridge channel if it is open. A game restarting on the PC reopens the channel under the
    /// same ID as a new object, while the old object can keep reporting ready and drop every
    /// message; so the cached object goes when the ID leaves the list, and `currentChannel(in:)`
    /// replaces it once a second.
    private func readyChannel(in session: FoveatedStreamingSession) -> FoveatedStreamingSession.MessageChannel? {
        guard session.availableMessageChannels.contains(Self.channelID) else {
            dropChannel()
            return nil
        }
        if let channel, channel.channelStatus == .ready {
            return channel
        }
        // A channel visionOS can't open logs an error on every lookup, so retry once a second.
        let now = CACurrentMediaTime()
        guard now - lastChannelLookup >= 1 else { return nil }
        lastChannelLookup = now
        return currentChannel(in: session)
    }

    private static let channelID = FoveatedStreamingSession.MessageChannel.ID(ControllerBridgeProtocol.channelUUID)

    /// The session's own object for the bridge channel, adopted if it differs from the cached one.
    @discardableResult
    private func currentChannel(in session: FoveatedStreamingSession) -> FoveatedStreamingSession.MessageChannel? {
        guard session.availableMessageChannels.contains(Self.channelID) else {
            dropChannel()
            return nil
        }
        guard let found = session.messageChannel(for: Self.channelID) else {
            dropChannel()
            failedChannelLookups += 1
            if failedChannelLookups == 3 {
                logger.error("visionOS can't open the bridge channel; relaunch the app to restore controllers")
                ControllerBridgeStatus.shared.isChannelUnavailable = true
            }
            return nil
        }
        failedChannelLookups = 0
        ControllerBridgeStatus.shared.isChannelUnavailable = false
        guard found.channelStatus == .ready else {
            dropChannel()
            return nil
        }
        if found !== channel {
            logger.notice("Bridge channel open")
            channel = found
            receiveHaptics(on: found)
        }
        return found
    }

    private func dropChannel() {
        guard channel != nil else { return }
        logger.notice("Bridge channel closed")
        channel = nil
    }

    private func receiveHaptics(on channel: FoveatedStreamingSession.MessageChannel) {
        hapticTask?.cancel()
        hapticTask = Task {
            for await message in channel.receivedMessageStream {
                handleHapticMessage(message)
            }
            // The stream ends when the channel closes.
            stopAllHaptics()
        }
    }

    // MARK: - Haptics

    private func handleHapticMessage(_ message: Data) {
        guard let haptic = ControllerBridgeHaptic(message) else {
            logger.error("Dropped malformed haptic packet of \(message.count) bytes")
            return
        }
        let hand: Hand = haptic.hand == .left ? .left : .right
        let amplitude = haptic.amplitude.isFinite ? min(max(haptic.amplitude, 0), 1) : 0
        guard haptic.command == .apply, amplitude > 0 else {
            stopHaptic(hand)
            return
        }
        let seconds = TimeInterval(haptic.durationNs) / 1_000_000_000
        let duration = min(max(seconds, Self.minimumHapticDuration), Self.maximumHapticDuration)
        playHaptic(hand, duration: duration, intensity: amplitude * Self.hapticIntensityScale)
    }

    /// Replaces whatever plays on that hand. CoreHaptics has no frequency control, so the packet's
    /// frequency goes unused and sharpness stays at 1.
    private func playHaptic(_ hand: Hand, duration: TimeInterval, intensity: Float, isRetry: Bool = false) {
        guard let engine = hapticEngine(for: hand) else { return }
        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1),
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                ], relativeTime: 0, duration: duration),
            ], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            stopHaptic(hand)
            try player.start(atTime: CHHapticTimeImmediate)
            hands[hand]?.hapticPlayer = player
        } catch {
            logger.error("Haptic playback failed on \(hand.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            engine.stop()
            hands[hand]?.hapticEngine = nil
            hands[hand]?.hapticPlayer = nil
            // An engine the system stopped or reset fails here, and a fresh one usually plays.
            if !isRetry {
                playHaptic(hand, duration: duration, intensity: intensity, isRetry: true)
            }
        }
    }

    private func stopHaptic(_ hand: Hand) {
        try? hands[hand]?.hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hands[hand]?.hapticPlayer = nil
    }

    private func stopAllHaptics() {
        Hand.allCases.forEach(stopHaptic)
    }

    private func hapticEngine(for hand: Hand) -> CHHapticEngine? {
        if let engine = hands[hand]?.hapticEngine {
            return engine
        }
        guard let haptics = hands[hand]?.controller?.haptics else { return nil }
        let suffix = hand == .left ? "(L)" : "(R)"
        let engine = haptics.createEngine(withLocality: hand == .left ? .leftHandle : .rightHandle)
            ?? haptics.supportedLocalities.first { ($0.rawValue as String).contains(suffix) }
                .flatMap { haptics.createEngine(withLocality: $0) }
            ?? haptics.createEngine(withLocality: .all)
        do {
            try engine?.start()
        } catch {
            logger.error("Haptic engine failed to start on \(hand.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        hands[hand]?.hapticEngine = engine
        return engine
    }

    // MARK: - Controller state

    private func handBlock(_ hand: Hand, anchors: [AccessoryAnchor]) -> ControllerBridgeHand? {
        guard let controller = hands[hand]?.controller else { return nil }
        var block = ControllerBridgeHand()
        Self.readInput(controller.input.capture(), into: &block)
        if let anchor = anchors.first(where: { Self.hand(of: $0.accessory) == hand }) {
            writePose(of: anchor, into: &block)
        } else {
            block.sampleTimeNs = Self.nanoseconds(CACurrentMediaTime())
        }
        return block
    }

    /// `capture()` snapshots the live state without draining the input queue. "Button A" drives A
    /// on the right hand and X on the left.
    private static func readInput(_ input: any GCDevicePhysicalInputState, into block: inout ControllerBridgeHand) {
        let buttons = input.buttons
        func pressed(_ name: String) -> Bool { buttons[name]?.pressedInput.isPressed ?? false }
        func touched(_ name: String) -> Bool { buttons[name]?.touchedInput?.isTouched ?? false }

        let mapping: [(name: String, press: ControllerBridgeHand.Buttons?, touch: ControllerBridgeHand.Buttons)] = [
            ("Button A", .buttonA, .touchButtonA),
            ("Button B", .buttonB, .touchButtonB),
            ("Trigger", .trigger, .touchTrigger),
            ("Grip", .grip, .touchGrip),
            ("Thumbstick Button", .thumbstickClick, .touchThumbstick),
            ("Button Menu", .menu, []),
        ]
        for element in mapping {
            if let press = element.press, pressed(element.name) {
                block.buttons.insert(press)
            }
            if touched(element.name) {
                block.buttons.insert(element.touch)
            }
        }
        block.trigger = buttons["Trigger"]?.pressedInput.value ?? 0
        block.grip = buttons["Grip"]?.pressedInput.value ?? 0
        if let stick = input.dpads["Thumbstick"] {
            block.thumbstick = SIMD2(stick.xAxis.value, stick.yAxis.value)
        }
    }

    /// Writes the head-relative grip and aim poses and the grip velocity at the anchor's timestamp.
    private func writePose(of anchor: AccessoryAnchor, into block: inout ControllerBridgeHand) {
        block.sampleTimeNs = Self.nanoseconds(anchor.timestamp)
        guard let head = deviceAnchor(at: anchor.timestamp), head.trackingState != .untracked else { return }

        let originFromHead = head.originFromAnchorTransform
        let headFromOrigin = originFromHead.inverse
        let originFromGrip = anchor.coordinateSpace(for: .grip, correction: .none).ancestorFromSpaceTransformFloat().matrix
        let originFromAim = anchor.coordinateSpace(for: .aim, correction: .none).ancestorFromSpaceTransformFloat().matrix
        block.gripPose = Self.pose(headFromOrigin * originFromGrip)
        block.aimPose = Self.pose(headFromOrigin * originFromAim)

        let anchorRotation = anchor.originFromAnchorTransform.rotation
        let gripPosition = originFromGrip.translation
        let leverArm = gripPosition - anchor.originFromAnchorTransform.translation
        let angularVelocity = anchorRotation * anchor.angularVelocity
        let linearVelocity = anchorRotation * anchor.velocity + simd_cross(angularVelocity, leverArm)
        let headRotationInverse = originFromHead.rotation.transpose
        block.linearVelocity = headRotationInverse * linearVelocity
        block.angularVelocity = headRotationInverse * angularVelocity

        var flags: ControllerBridgeHand.TrackingFlags = switch anchor.trackingState {
        case .positionOrientationTracked: .tracked
        case .positionOrientationTrackedLowAccuracy: ControllerBridgeHand.TrackingFlags.tracked.union(.lowAccuracy)
        case .orientationTracked: [.orientationValid, .orientationTracked]
        default: []
        }
        if head.trackingState == .orientationTracked {
            flags.subtract([.positionValid, .positionTracked])
        }
        block.trackingFlags = flags
    }

    private static func pose(_ transform: simd_float4x4) -> ControllerBridgePose {
        ControllerBridgePose(position: transform.translation, orientation: simd_quatf(transform.rotation).normalized)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }

    // MARK: - Controllers and tracking

    private func controllersChanged() {
        refreshControllers()
        guard isActive else { return }
        // Stream start disconnects and reconnects both controllers in a burst; one restart covers it.
        scheduleAccessoryRestart(after: .milliseconds(250), attempt: 1)
    }

    private func refreshControllers() {
        var found: [Hand: GCController] = [:]
        for controller in GCController.spatialControllers {
            if let hand = Self.hand(of: controller) {
                found[hand] = controller
            }
        }
        for hand in Hand.allCases where hands[hand]?.controller !== found[hand] {
            stopHaptic(hand)
            hands[hand]?.hapticEngine?.stop()
            hands[hand]?.hapticEngine = nil
            hands[hand]?.controller = found[hand]
        }
        ControllerBridgeStatus.shared.leftControllerName = found[.left]?.vendorName
        ControllerBridgeStatus.shared.rightControllerName = found[.right]?.vendorName
        let left = found[.left]?.vendorName ?? "none"
        let right = found[.right]?.vendorName ?? "none"
        logger.notice("Spatial controllers: left=\(left, privacy: .public) right=\(right, privacy: .public)")
    }

    private func scheduleAccessoryRestart(after delay: Duration, attempt: Int) {
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await restartAccessoryTracking(attempt: attempt)
        }
    }

    /// `latestAnchors` and `queryDeviceAnchor` log an error on every call while their provider is paused.
    private func runningAnchors() -> [AccessoryAnchor] {
        guard let accessoryTracking, accessoryTracking.state == .running else { return [] }
        return accessoryTracking.latestAnchors
    }

    private func deviceAnchor(at timestamp: TimeInterval) -> DeviceAnchor? {
        guard let worldTracking, worldTracking.state == .running else { return nil }
        return worldTracking.queryDeviceAnchor(atTimestamp: timestamp)
    }

    private func restartWorldTracking() async {
        guard !isStartingWorldTracking else { return }
        isStartingWorldTracking = true
        defer { isStartingWorldTracking = false }
        stopWorldTracking()
        let session = ARKitSession()
        let provider = WorldTrackingProvider()
        let events = watchEvents(of: session, label: "World")
        do {
            try await session.run([provider])
        } catch {
            events.cancel()
            logger.error("World tracking failed to start: \(String(describing: error), privacy: .public)")
            return
        }
        guard isActive else {
            events.cancel()
            session.stop()
            return
        }
        worldSession = session
        worldTracking = provider
        sessionEventTasks.append(events)
    }

    private func stopWorldTracking() {
        sessionEventTasks.forEach { $0.cancel() }
        sessionEventTasks = []
        worldSession?.stop()
        worldSession = nil
        worldTracking = nil
    }

    private func restartAccessoryTracking(attempt: Int = 1) async {
        guard AccessoryTrackingProvider.isSupported else {
            logger.error("AccessoryTrackingProvider is not supported on this device")
            return
        }
        trackingGeneration += 1
        let generation = trackingGeneration
        lastAccessoryRestart = CACurrentMediaTime()
        stopAccessoryTracking()

        let controllers = GCController.spatialControllers
        var accessories: [Accessory] = []
        for controller in controllers {
            do {
                accessories.append(try await Accessory(device: controller))
            } catch {
                logger.error("Accessory init failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard isActive, generation == trackingGeneration else { return }
        logger.notice("Tracking accessories (attempt \(attempt)): \(accessories.map(\.name).joined(separator: ", "), privacy: .public)")
        let missing = accessories.count < controllers.count
        // Scheduled on exit: the restart task may be the one running this call, and cancelling
        // it before `run` would abandon the controllers that did load.
        defer {
            if missing, attempt < Self.accessoryAttempts, isActive, generation == trackingGeneration {
                scheduleAccessoryRestart(after: .seconds(1), attempt: attempt + 1)
            }
        }
        guard !accessories.isEmpty else { return }

        // A provider runs only once, so a changed controller set gets a fresh session.
        let session = ARKitSession()
        let provider = AccessoryTrackingProvider(accessories: accessories)
        let events = watchEvents(of: session, label: "Accessory \(generation)")
        do {
            try await session.run([provider])
        } catch {
            events.cancel()
            logger.error("Accessory tracking failed to start: \(String(describing: error), privacy: .public)")
            return
        }
        guard isActive, generation == trackingGeneration else {
            events.cancel()
            session.stop()
            return
        }
        accessorySession = session
        accessoryTracking = provider
        accessoryEventTask = events
    }

    private func stopAccessoryTracking() {
        accessoryEventTask?.cancel()
        accessoryEventTask = nil
        accessorySession?.stop()
        accessorySession = nil
        accessoryTracking = nil
    }

    /// Logs provider state changes and their errors, which `run` does not report once it returns.
    private func watchEvents(of session: ARKitSession, label: String) -> Task<Void, Never> {
        Task {
            for await event in session.events {
                guard !Task.isCancelled else { break }
                logger.notice("\(label, privacy: .public) session event: \(String(describing: event), privacy: .public)")
            }
        }
    }

    // MARK: - Once per second

    /// Restarts providers that stay stopped or paused while the session is connected, which a
    /// session pause leaves behind if they do not resume on their own, and logs channel changes.
    private func monitorSecond() async {
        guard let session else { return }
        let connected = session.status == .connected
        if connected, channel != nil {
            currentChannel(in: session)
        }
        let hasControllers = hands.values.contains { $0.controller != nil }
        stalledSeconds.world = connected && worldTracking?.state != .running ? stalledSeconds.world + 1 : 0
        // A restart in progress has no provider yet; give it the same time before counting.
        let restartSettled = CACurrentMediaTime() - lastAccessoryRestart > Double(Self.stalledProviderLimit)
        stalledSeconds.accessories = connected && hasControllers && restartSettled
            && accessoryTracking?.state != .running ? stalledSeconds.accessories + 1 : 0
        if stalledSeconds.world >= Self.stalledProviderLimit {
            stalledSeconds.world = 0
            logger.notice("Restarting stalled world tracking")
            await restartWorldTracking()
        }
        if stalledSeconds.accessories >= Self.stalledProviderLimit {
            stalledSeconds.accessories = 0
            logger.notice("Restarting stalled accessory tracking")
            await restartAccessoryTracking()
        }
        if sendFailures > 0 {
            logger.error("\(self.sendFailures) bridge packets failed to send in the last second")
            sendFailures = 0
        }
        // The list shows whether the PC layer's channel reached the headset.
        let available = session.availableMessageChannels
        if connected, available != loggedChannels {
            loggedChannels = available
            let list = available.map { "\($0)" }.joined(separator: ", ")
            logger.notice("Message channels: \(available.isEmpty ? "none" : list, privacy: .public)")
        }
    }

    private static func hand(of controller: GCController) -> Hand? {
        guard let name = controller.vendorName else { return nil }
        if name.contains("(L)") { return .left }
        if name.contains("(R)") { return .right }
        return nil
    }

    private static func hand(of accessory: Accessory) -> Hand? {
        switch accessory.inherentChirality {
        case .left: .left
        case .right: .right
        default: nil
        }
    }
}

private extension GCController {
    /// Spatially tracked controllers, such as PSVR2 Sense, among all connected controllers.
    static var spatialControllers: [GCController] {
        controllers().filter { $0.productCategory == GCProductCategorySpatialController }
    }
}

private extension simd_float4x4 {
    var rotation: simd_float3x3 {
        simd_float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z),
                      SIMD3(columns.1.x, columns.1.y, columns.1.z),
                      SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }

    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}
#endif
