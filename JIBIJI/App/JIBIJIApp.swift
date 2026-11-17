import SwiftUI

@main
struct JIBIJIApp: App {
    @State private var notebook = NotebookModel(store: .forLaunch())
    @State private var notebookIsOpen = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if notebookIsOpen {
                    NotePageView(notebook: notebook, showCover: {
                        notebook.saveAll()
                        notebookIsOpen = false
                    })
                } else {
                    NotebookCoverView { notebookIsOpen = true }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Autosave runs after each writing pause; this catches the last few
            // strokes when the app leaves the foreground before that pause ends.
            if phase != .active {
                notebook.saveAll()
            }
        }
    }
}
