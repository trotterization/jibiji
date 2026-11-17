import SwiftUI

@main
struct JIBIJIApp: App {
    @State private var notebook = NotebookModel(store: .forLaunch())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(notebook: notebook)
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

/// Switches between the cover and the notebook. The flag lives in a view, not in the `App`,
/// so the change between the two screens animates.
private struct RootView: View {
    let notebook: NotebookModel
    @State private var notebookIsOpen = false

    var body: some View {
        ZStack {
            if notebookIsOpen {
                NotePageView(notebook: notebook, showCover: {
                    notebook.saveAll()
                    withAnimation(Theme.Motion.screen) { notebookIsOpen = false }
                })
                // Opacity only: the canvas and its tool bar need their final frame from the start.
                .transition(.opacity)
            } else {
                NotebookCoverView(isStill: notebook.usesTestNotebook) {
                    withAnimation(Theme.Motion.screen) { notebookIsOpen = true }
                }
                // The cover runs its own dive into the page; this only fades what is left.
                .transition(.opacity)
            }
        }
        // Same surface as both screens, so nothing flashes while they cross over.
        .background(Theme.surface.ignoresSafeArea())
    }
}
