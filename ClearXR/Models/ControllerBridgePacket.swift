/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The controller packets' wire format, specified in clearxr-server's clearxr-layer/PROTOCOL.md.
*/

import Foundation
import simd

enum ControllerBridgeProtocol {
    /// Clear XR's opaque data channel, which also carries the stream configuration packets.
    static let channelUUID = UUID(uuidString: "78563412-3412-3412-1234-56789ABCDEF0")!
}

struct ControllerBridgePose: Equatable {
    var position: SIMD3<Float> = .zero
    var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
}

/// One hand's block. Poses and velocities are in the head frame.
struct ControllerBridgeHand: Equatable {
    struct Buttons: OptionSet {
        let rawValue: UInt16
        static let buttonA = Buttons(rawValue: 1 << 0)
        static let buttonB = Buttons(rawValue: 1 << 1)
        static let trigger = Buttons(rawValue: 1 << 2)
        static let grip = Buttons(rawValue: 1 << 3)
        static let thumbstickClick = Buttons(rawValue: 1 << 4)
        static let menu = Buttons(rawValue: 1 << 5)
        static let touchButtonA = Buttons(rawValue: 1 << 6)
        static let touchButtonB = Buttons(rawValue: 1 << 7)
        static let touchTrigger = Buttons(rawValue: 1 << 8)
        static let touchGrip = Buttons(rawValue: 1 << 9)
        static let touchThumbstick = Buttons(rawValue: 1 << 10)
    }

    /// Bits 0–3 equal OpenXR's `XrSpaceLocationFlags`.
    struct TrackingFlags: OptionSet {
        let rawValue: UInt16
        static let orientationValid = TrackingFlags(rawValue: 1 << 0)
        static let positionValid = TrackingFlags(rawValue: 1 << 1)
        static let orientationTracked = TrackingFlags(rawValue: 1 << 2)
        static let positionTracked = TrackingFlags(rawValue: 1 << 3)
        static let linearVelocityValid = TrackingFlags(rawValue: 1 << 4)
        static let angularVelocityValid = TrackingFlags(rawValue: 1 << 5)
        static let lowAccuracy = TrackingFlags(rawValue: 1 << 6)

        static let tracked: TrackingFlags = [
            .orientationValid, .positionValid, .orientationTracked, .positionTracked,
            .linearVelocityValid, .angularVelocityValid,
        ]
    }

    var sampleTimeNs: UInt64 = 0
    var buttons: Buttons = []
    var trackingFlags: TrackingFlags = []
    var thumbstick: SIMD2<Float> = .zero
    var trigger: Float = 0
    var grip: Float = 0
    var gripPose = ControllerBridgePose()
    var aimPose = ControllerBridgePose()
    var linearVelocity: SIMD3<Float> = .zero
    var angularVelocity: SIMD3<Float> = .zero
}

/// Controller packet, version 2. A nil hand has no connected controller.
struct ControllerBridgePacket {
    static let magic: UInt16 = 0x5343
    static let version: UInt8 = 2
    static let size = 248
    static let headRelative: UInt16 = 1 << 0

    var sequence: UInt32 = 0
    var sendTimeNs: UInt64 = 0
    var left: ControllerBridgeHand?
    var right: ControllerBridgeHand?

    func encoded() -> Data {
        var writer = LittleEndianWriter(capacity: Self.size)
        let activeHands: UInt8 = (left == nil ? 0 : 1) | (right == nil ? 0 : 2)
        writer.put(Self.magic)
        writer.put(Self.version)
        writer.put(activeHands)
        writer.put(Self.headRelative)
        writer.put(UInt16(0))
        writer.put(sequence)
        writer.put(UInt32(0))
        writer.put(sendTimeNs)
        for hand in [left, right] {
            let hand = hand ?? ControllerBridgeHand()
            writer.put(hand.sampleTimeNs)
            writer.put(hand.buttons.rawValue)
            writer.put(hand.trackingFlags.rawValue)
            writer.put(UInt32(0))
            writer.put(hand.thumbstick.x)
            writer.put(hand.thumbstick.y)
            writer.put(hand.trigger)
            writer.put(hand.grip)
            writer.put(hand.gripPose)
            writer.put(hand.aimPose)
            writer.put(hand.linearVelocity)
            writer.put(hand.angularVelocity)
        }
        assert(writer.bytes.count == Self.size)
        return Data(writer.bytes)
    }
}

/// Haptic packet, version 2, as decoded: the playback limits in PROTOCOL.md apply later.
struct ControllerBridgeHaptic: Equatable {
    enum Hand: UInt8 {
        case left = 0
        case right = 1
    }

    enum Command: UInt8 {
        case apply = 0
        case stop = 1
    }

    static let magic: UInt16 = 0x4856
    static let version: UInt8 = 2
    static let size = 24

    var hand: Hand
    var command: Command
    var durationNs: UInt64
    var frequency: Float
    var amplitude: Float

    /// Returns nil for any packet PROTOCOL.md's receiving rules reject.
    init?(_ data: Data) {
        guard data.count >= 4 else { return nil }
        let fields: (UInt16, UInt8, UInt8, UInt8, UInt64, UInt32, UInt32) = data.withUnsafeBytes { raw in
            func load<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
                offset + MemoryLayout<T>.size <= raw.count
                    ? T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self)) : 0
            }
            return (load(0, UInt16.self), load(2, UInt8.self), load(3, UInt8.self), load(4, UInt8.self),
                    load(8, UInt64.self), load(16, UInt32.self), load(20, UInt32.self))
        }
        guard fields.0 == Self.magic, fields.1 == Self.version, data.count >= Self.size,
              let hand = Hand(rawValue: fields.2), let command = Command(rawValue: fields.3) else {
            return nil
        }
        self.hand = hand
        self.command = command
        durationNs = fields.4
        frequency = Float(bitPattern: fields.5)
        amplitude = Float(bitPattern: fields.6)
    }
}

private struct LittleEndianWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func put(_ value: Float) {
        put(value.bitPattern)
    }

    mutating func put(_ value: SIMD3<Float>) {
        put(value.x)
        put(value.y)
        put(value.z)
    }

    mutating func put(_ pose: ControllerBridgePose) {
        put(pose.position)
        // `simd_quatf.vector` is (x, y, z, w), the wire order.
        let q = pose.orientation.vector
        put(q.x)
        put(q.y)
        put(q.z)
        put(q.w)
    }
}
