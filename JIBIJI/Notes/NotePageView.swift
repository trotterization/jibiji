import PencilKit
import SwiftUI

/// The local notebook: pick a page from the Pages menu, add pages, write with Apple Pencil.
struct NotePageView: View {
    @Bindable var notebook: NotebookModel
    var showCover: (() -> Void)? = nil
    @State private var canvas = CanvasController()
    @State private var showsRecognitionCheck = false
    @State private var showsCards = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { bar }
            .tint(.primary)
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
            .rises(distance: 0)
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
    /// The floating bar above the page: where you are on the left, what you can do on the right.
    private var bar: some View {
        HStack(spacing: 4) {
            if let showCover {
                Button(action: showCover) {
                    Text("jibiji")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("Cover")
                .accessibilityIdentifier("showCover")
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 8)
            }
            Menu {
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
            } label: {
                Label("Pages", systemImage: "square.on.square")
            }
            .buttonStyle(BarIconButtonStyle())
            .disabled(notebook.loadState != .ready)
            .accessibilityIdentifier("pagesMenu")

            HStack(spacing: 10) {
                Text(currentTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("pageTitle")
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(currentPage?.statusText ?? "")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.58))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("pageStatus")
                }
            }
            .lineLimit(1)
            .padding(.leading, 6)
            .animation(Theme.Motion.quick, value: currentTitle)
            .animation(Theme.Motion.quick, value: currentPage?.statusText)

            Spacer(minLength: 8)

            if let suggestions = currentPage?.suggestions, suggestions.canUndo {
                Button("Undo suggestion", systemImage: "arrow.uturn.backward") {
                    suggestions.undoLastAccept()
                }
                .buttonStyle(BarIconButtonStyle())
                .accessibilityIdentifier("undoSuggestion")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Button("Cards", systemImage: "rectangle.on.rectangle") {
                currentPage?.saveIfNeeded()
                canvas.resignFocus()
                showsCards = true
            }
            .buttonStyle(BarIconButtonStyle())
            .disabled(!(currentPage?.isEditable ?? false))
            .accessibilityIdentifier("cardsButton")
            Button("Check recognition", systemImage: "text.viewfinder") {
                currentPage?.saveIfNeeded()
                canvas.resignFocus()
                showsRecognitionCheck = true
            }
            .buttonStyle(BarIconButtonStyle())
            .disabled(!(currentPage?.isEditable ?? false))
            Button {
                guard let page = currentPage else { return }
                page.suggestions.request(for: page.drawing)
            } label: {
                SuggestLabel(isReading: currentPage?.suggestions.status == .checking)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!(currentPage?.isEditable ?? false))
            .accessibilityLabel("Suggest")
            .accessibilityIdentifier("suggestButton")
            .padding(.leading, 6)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 54)
        .background(Theme.bar, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(Theme.Motion.list, value: currentPage?.suggestions.canUndo)
        .rises(after: 0.05, distance: -10)
    }

    private var statusColor: Color {
        switch currentPage?.state {
        case .saved: Theme.saved
        case .unsaved: Theme.pending
        case .failed, .cannotOpen: Theme.problem
        default: .white.opacity(0.28)
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

/// The bar's one filled control. While the page is being read, three dots take turns.
private struct SuggestLabel: View {
    let isReading: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            Text("Suggest").opacity(isReading ? 0 : 1)
            if isReading {
                ReadingDots().transition(.opacity)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color(white: 0.1))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.white.opacity(isEnabled ? 1 : 0.3), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .animation(Theme.Motion.quick, value: isReading)
    }
}

private struct ReadingDots: View {
    @State private var running = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(running ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.16), value: running)
            }
        }
        .onAppear { running = true }
        .accessibilityHidden(true)
    }
}
