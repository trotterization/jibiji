import PencilKit
import SwiftUI

/// The first JIBIJI page: write with Apple Pencil, autosave, and reopen the same ink.
struct NotePageView: View {
    @Bindable var model: NotePageModel
    @State private var canvas = CanvasController()
    @State private var showsRecognitionCheck = false

    var body: some View {
        NavigationStack {
            page
                .navigationTitle("Page 1")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .alert("Page kept safe", isPresented: showsNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        .sheet(isPresented: $showsRecognitionCheck, onDismiss: canvas.focus) {
            RecognitionCheckView(drawing: model.drawing)
        }
    }

    @ViewBuilder
    private var page: some View {
        if case .cannotOpen(let reason) = model.state {
            ContentUnavailableView {
                Label("Can't open this page", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Editing is paused so the saved file isn't overwritten.\n\(reason)")
            }
        } else {
            PencilCanvasView(
                initialDrawing: model.drawing,
                controller: canvas,
                startsWithPenWithoutSavingTools: model.usesTestNotebook
            ) { drawing in
                model.drawingDidChange(drawing)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    // Undo, redo, and the eraser live in the system tool palette, as in other iPadOS writing apps.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text("Page 1")
                    .font(.headline)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(statusStyle)
                    .accessibilityIdentifier("pageStatus")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Check recognition", systemImage: "text.viewfinder") {
                model.saveIfNeeded()
                canvas.resignFocus()
                showsRecognitionCheck = true
            }
            .disabled(!model.isEditable)
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch model.state {
        case .failed, .cannotOpen: AnyShapeStyle(.red)
        default: AnyShapeStyle(.secondary)
        }
    }

    private var showsNotice: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )
    }
}
