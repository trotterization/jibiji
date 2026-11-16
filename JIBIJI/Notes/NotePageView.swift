import PencilKit
import SwiftUI

/// The local notebook: pick a page from the Pages menu, add pages, write with Apple Pencil.
struct NotePageView: View {
    @Bindable var notebook: NotebookModel
    @State private var canvas = CanvasController()
    @State private var showsRecognitionCheck = false
    @State private var showsCards = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(currentTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .alert("Page kept safe", isPresented: showsNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(currentPage?.notice ?? "")
        }
        .alert("Notebook", isPresented: showsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notebook.alert ?? "")
        }
        .sheet(isPresented: $showsCards, onDismiss: canvas.focus) {
            if let page = currentPage {
                FlashcardsView(page: page)
            }
        }
        .sheet(isPresented: $showsRecognitionCheck, onDismiss: canvas.focus) {
            // Always the page that was active when the button was tapped (the sheet covers the menu).
            RecognitionCheckView(drawing: currentPage?.drawing ?? PKDrawing())
        }
    }

    private var currentPage: NotePageModel? { notebook.currentPage }
    private var currentTitle: String { notebook.title(for: notebook.currentPageID) }

    @ViewBuilder
    private var content: some View {
        if case .failed(let reason) = notebook.loadState {
            ContentUnavailableView {
                Label("Can't open the notebook", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Nothing has been changed or deleted.\n\(reason)")
            } actions: {
                Button("Try Again") { notebook.reload() }
                    .accessibilityIdentifier("retryNotebook")
            }
            .accessibilityIdentifier("notebookError")
        } else if let page = currentPage {
            pageContent(page)
        }
    }

    @ViewBuilder
    private func pageContent(_ page: NotePageModel) -> some View {
        if case .cannotOpen(let reason) = page.state {
            ContentUnavailableView {
                Label("Can't open this page", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Editing is paused so the saved file isn't overwritten.\n\(reason)")
            }
        } else {
            PencilCanvasView(
                initialDrawing: page.drawing,
                controller: canvas,
                startsWithPenWithoutSavingTools: page.usesTestNotebook,
                noteBottom: page.suggestions.noteBottom ?? 0
            ) { drawing in
                // Bound to this page's model, so a late callback can only reach its own page.
                page.drawingDidChange(drawing)
            }
            // Same frame as the canvas, so suggestions can follow its scroll offset.
            .overlay { SuggestionOverlay(suggestions: page.suggestions, drawing: page.drawing, canvas: canvas) }
            // A separate canvas (and tool picker) per page.
            .id(page.pageID)
            // Scoped to this page's identity; accepted notes are kept.
            .onDisappear { page.suggestions.cancelPending() }
            .ignoresSafeArea(.container, edges: .bottom)
            // The page never types text. If a software keyboard appears (Simulator without a
            // hardware keyboard), it must not resize the canvas, which re-lays out and rescrolls the ink.
            .ignoresSafeArea(.keyboard)
        }
    }

    // Undo, redo, and the eraser live in the system tool palette, as in other iPadOS writing apps.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu("Pages", systemImage: "book.pages") {
                ForEach(notebook.pageIDs, id: \.self) { id in
                    Button {
                        notebook.selectPage(id)
                    } label: {
                        if id == notebook.currentPageID {
                            Label(notebook.title(for: id), systemImage: "checkmark")
                        } else {
                            Text(notebook.title(for: id))
                        }
                    }
                    .accessibilityIdentifier("pageItem-\(id)")
                }
                Divider()
                Button("New Page", systemImage: "plus") {
                    notebook.createPage()
                }
                .accessibilityIdentifier("newPageButton")
            }
            .disabled(notebook.loadState != .ready)
            .accessibilityIdentifier("pagesMenu")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(currentTitle)
                    .font(.headline)
                    .accessibilityIdentifier("pageTitle")
                Text(currentPage?.statusText ?? "")
                    .font(.caption)
                    .foregroundStyle(statusStyle)
                    .accessibilityIdentifier("pageStatus")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let suggestions = currentPage?.suggestions, suggestions.canUndo {
                Button("Undo suggestion", systemImage: "arrow.uturn.backward.circle") {
                    suggestions.undoLastAccept()
                }
                .accessibilityIdentifier("undoSuggestion")
            }
            Button("Suggest", systemImage: "text.badge.plus") {
                guard let page = currentPage else { return }
                page.suggestions.request(for: page.drawing)
            }
            .disabled(!(currentPage?.isEditable ?? false))
            .accessibilityIdentifier("suggestButton")
            Button("Cards", systemImage: "rectangle.on.rectangle") {
                currentPage?.saveIfNeeded()
                canvas.resignFocus()
                showsCards = true
            }
            .disabled(!(currentPage?.isEditable ?? false))
            .accessibilityIdentifier("cardsButton")
            Button("Check recognition", systemImage: "text.viewfinder") {
                currentPage?.saveIfNeeded()
                canvas.resignFocus()
                showsRecognitionCheck = true
            }
            .disabled(!(currentPage?.isEditable ?? false))
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch currentPage?.state {
        case .failed, .cannotOpen: AnyShapeStyle(.red)
        default: AnyShapeStyle(.secondary)
        }
    }

    private var showsNotice: Binding<Bool> {
        Binding(
            get: { currentPage?.notice != nil },
            set: { if !$0 { currentPage?.notice = nil } }
        )
    }

    private var showsAlert: Binding<Bool> {
        Binding(
            get: { notebook.alert != nil },
            set: { if !$0 { notebook.alert = nil } }
        )
    }
}
