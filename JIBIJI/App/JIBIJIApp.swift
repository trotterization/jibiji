import SwiftUI

@main
struct JIBIJIApp: App {
    @State private var page = NotePageModel(pageID: NotePageModel.firstPageID, store: .forLaunch())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NotePageView(model: page)
        }
        .onChange(of: scenePhase) { _, phase in
            // Autosave runs after each writing pause; this catches the last few
            // strokes when the app leaves the foreground before that pause ends.
            if phase != .active {
                page.saveIfNeeded()
            }
        }
    }
}
