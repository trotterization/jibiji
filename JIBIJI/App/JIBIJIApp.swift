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
                // Opacity only: the canvas and its tool palette need their final frame from the start.
                .transition(.opacity)
            } else {
                NotebookCoverView {
                    withAnimation(Theme.Motion.screen) { notebookIsOpen = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        // The cover's black shows through while the two screens cross over.
        .background(Color.black.ignoresSafeArea())
    }
}
