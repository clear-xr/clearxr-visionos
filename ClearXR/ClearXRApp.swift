/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The SwiftUI `App` structure, which acts as the entry point of the app. Defines the windows and spaces the app uses as well as global state.
*/

import SwiftUI
import RealityKit
import GameController

#if targetEnvironment(simulator)
import ClearXRSimulator
#else
import FoveatedStreaming
#endif

@main
struct ClearXRApp: App {
    private let session = FoveatedStreamingSession()
    private let appModel = AppModel()

    #if !targetEnvironment(simulator)
    private let messageChannelModel: MessageChannelModel

    init() {
        messageChannelModel = MessageChannelModel(session: session)
    }
    #endif

    var body: some SwiftUI.Scene {
        Window("Main", id: appModel.mainWindowId) {
            ContentView(session: session)
                .environment(appModel)
                .environment(ControllerBridgeStatus.shared)
                #if !targetEnvironment(simulator)
                .environment(messageChannelModel)
                #endif
                .environment(session)
                .environment(
                    StreamActions(
                        connect: { endpoint in
                            try await session.connect(endpoint: endpoint)
                        },
                        pause: {
                            try await session.pause()
                        },
                        resume: {
                            try await session.resume()
                        },
                        disconnect: {
                            await session.disconnect()
                        }
                    )
                )
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        #if !targetEnvironment(simulator)
        ImmersiveSpace(foveatedStreaming: session) {
            SpatialContainer {
                ReopenMainWindowView()
                    .environment(appModel)
            }
            // visionOS turns controller input into pinches unless a view claims it, and then
            // GCController reports no buttons at all. Views still receive the events, so the
            // trigger keeps working as a pinch on this app's UI.
            .handlesGameControllerEvents(matching: .gamepad, withOptions: .receivesEventsInView(true))
            .task {
                await ControllerBridge.shared.start(session: session)
            }
            .onDisappear {
                ControllerBridge.shared.stop()
                // Digital crown dismissal — pause the stream.
                Task {
                    try? await session.pause()
                }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed, .full)
        .persistentSystemOverlays(.hidden)
        .upperLimbVisibility(.hidden)
        #endif
    }
}
