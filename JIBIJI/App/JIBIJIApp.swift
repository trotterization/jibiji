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

/// Switches between the cover, the notebook's home, and a page. The screen lives in a view, not
/// in the `App`, so the changes between them animate.
private struct RootView: View {
    enum Screen { case cover, home, page }

    let notebook: NotebookModel
    @State private var screen = Screen.cover
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            switch screen {
            case .page:
                NotePageView(notebook: notebook, showHome: {
                    notebook.saveAll()
                    withAnimation(Theme.Motion.screen) { screen = .home }
                })
                // Opacity only: the canvas and its tool bar need their final frame from the start.
                .transition(.opacity)
            case .home:
                HomeView(notebook: notebook, openPage: { id in
                    notebook.openPage(id)
                    withAnimation(Theme.Motion.screen) { screen = .page }
                }, showCover: {
                    notebook.saveAll()
                    withAnimation(Theme.Motion.screen) { screen = .cover }
                })
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .cover:
                NotebookCoverView(isStill: notebook.usesTestNotebook) {
                    withAnimation(Theme.Motion.screen) { screen = .home }
                }
                // The cover runs its own dive into the page; this only fades what is left.
                .transition(.opacity)
            }
        }
        // Same surface as every screen, so nothing flashes while they cross over.
        .background(Theme.surface.ignoresSafeArea())
        .onChange(of: screen) { _, screen in notebook.pageIsOpen = screen == .page }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await notebook.sync.synchronize(notebook)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
}
