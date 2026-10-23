import SwiftUI

@main
struct LyricsInTheCarApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = LyricsSession.live()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.send(.reconcilePlayback) }
        }
    }
}
