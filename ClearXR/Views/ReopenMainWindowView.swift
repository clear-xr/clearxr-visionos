/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An immersive view that displays a button to reopen the main window
  if the person has closed it.
*/

import SwiftUI
import RealityKit

struct ReopenMainWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    let reopenMainWindowEntity = Entity()
    
    var body: some View {
        RealityView { content in
            reopenMainWindowEntity.components.set(ViewAttachmentComponent(rootView:
                Button("Open Controls", systemImage: "arrow.up.left.and.arrow.down.right") {
                    openWindow(id: appModel.mainWindowId)
                }
                .breakthroughEffect(.subtle)
            ))
            reopenMainWindowEntity.components.set(OpacityComponent(opacity: 0))
            reopenMainWindowEntity.position = [0, 1, -1]
            content.add(reopenMainWindowEntity)
            content.add(makeGazeCatcher())
        }
        .onChange(of: appModel.mainWindowState.isVisible, initial: true) {
            // Show the reopen button when the main window isn't visible and hide it otherwise.
            Entity.animate(appModel.mainWindowState.isVisible ? .easeOut(duration: 0.25) : .easeIn(duration: 0.25)) {
                reopenMainWindowEntity.components[OpacityComponent.self]?.opacity = appModel.mainWindowState.isVisible ? 0 : 1
            }
        }
    }

    /// Invisible walls around the user, so gaze always lands on this app's content. visionOS sends
    /// controller input to whatever is under the user's gaze; over the bare stream that is the
    /// provider extension, and this app receives no buttons. The root also carries the marker that
    /// runs the controller bridge every frame.
    private func makeGazeCatcher() -> Entity {
        let size: Float = 8
        let thickness: Float = 0.01
        let half = size / 2
        let walls: [(position: SIMD3<Float>, extent: SIMD3<Float>)] = [
            ([0, 0, -half], [size, size, thickness]),
            ([0, 0, half], [size, size, thickness]),
            ([-half, 0, 0], [thickness, size, size]),
            ([half, 0, 0], [thickness, size, size]),
            ([0, half, 0], [size, thickness, size]),
            ([0, -half, 0], [size, thickness, size]),
        ]
        let root = Entity()
        root.position = [0, 1.5, 0]
        root.components.set(ControllerBridgeComponent())
        for wall in walls {
            let entity = Entity()
            entity.position = wall.position
            entity.components.set(CollisionComponent(shapes: [.generateBox(size: wall.extent)]))
            entity.components.set(InputTargetComponent())
            root.addChild(entity)
        }
        return root
    }
}

#Preview(immersionStyle: .mixed) {
    ReopenMainWindowView()
        .environment(AppModel())
}
