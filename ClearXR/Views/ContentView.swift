/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The main content view.
*/

import SwiftUI
import GameController
#if targetEnvironment(simulator)
import ClearXRSimulator
#else
import FoveatedStreaming
#endif

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.scenePhase) var scenePhase

    @State var isShowingDisconnectAlert = false
    @State var disconnectReasonDescription: String? = nil
    
    let session: FoveatedStreamingSession
    
    var isDisconnected: Bool {
        switch session.status {
            case .disconnected, .initialized, .connecting: true
            default: false
        }
    }
    
    var body: some View {
        @Bindable var appModel = appModel
        VStack {
            if isDisconnected {
                StreamConnectionView()
                    .transition(.opacity.combined(with: .scale))
            } else {
                StreamControlsView(status: session.status)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.spring, value: isDisconnected)
        .onChange(of: session.status) {
            if case .disconnected(let disconnectReason) = session.status,
               disconnectReason != .appInitiatedDisconnect,
               disconnectReason != .unauthorized,
               disconnectReason != .endpointInitiatedDisconnect {
                disconnectReasonDescription = disconnectReason.errorDescription
                isShowingDisconnectAlert = true
            }
        }
        .alert(disconnectReasonDescription ?? "Unknown Reason", isPresented: $isShowingDisconnectAlert) {
            Button("OK") { }
        }
        .trackWindowState($appModel.mainWindowState)
#if !targetEnvironment(simulator)
        .task {
            await ControllerBridge.requestAuthorization()
        }
#endif
        // Keeps controller input flowing to the game while the user looks at this window during a
        // stream; buttons still act as pinches on the window.
        .handlesGameControllerEvents(matching: .gamepad, withOptions: .receivesEventsInView(true))
#if !targetEnvironment(simulator)
        .foveatedStreamingPauseSheet(session: .constant(session))
#endif
    }
}

#if targetEnvironment(simulator)
#Preview(windowStyle: .plain, traits: .fixedLayout(width: 1000, height: 850)) {
    @Previewable @State var isConnectionSuccessful: Bool = true
    let session = FoveatedStreamingSession()

    VStack {
        ContentView(session: session)
            .environment(
                StreamActions(
                    connect: { _ in
                        session.status = .connecting
                        try await Task.sleep(for: .seconds(1))
                        session.status = isConnectionSuccessful ?
                                .connected : .disconnected(.simulatorTestDisconnect)
                    },
                    pause: {
                        session.status = .pausing
                        try await Task.sleep(for: .seconds(1))
                        session.status = .paused
                    },
                    resume: {
                        session.status = .resuming
                        try await Task.sleep(for: .seconds(1))
                        session.status = .connected
                    },
                    disconnect: {
                        session.status = .disconnecting
                        try? await Task.sleep(for: .seconds(0.2))
                        session.status = .disconnected(.appInitiatedDisconnect)
                    }
                )
            )
            .environment(AppModel())
            .environment(ControllerBridgeStatus.shared)
            .ornament(attachmentAnchor: .parent(.bottomFront)) {
                Toggle(isOn: $isConnectionSuccessful) {
                    Text("isConnectionSuccessful")
                }
                .toggleStyle(.button)
            }
    }
}
#endif
