import PencilKit
import SwiftUI

/// Suggestions sit right under the line they read. One tap on Replace swaps that line's strokes
/// for clean handwriting in the same place; the result is ordinary ink. Right after a replacement,
/// a small chip offers Restore and Delete until you write again. Empty areas let Pencil and
/// touches through to the canvas.
struct SuggestionOverlay: View {
    let page: NotePageModel
    let canvas: CanvasController
    /// Where the floating bar ends, so the status line sits below it.
    var topInset: CGFloat = 0

    @State private var editing: PendingSuggestion?
    @State private var editText = ""
    /// The replacement just made, and the page's stroke count right after it. The chip under it
    /// stays until the page changes some other way.
    @State private var recent: (id: UUID, strokes: Int)?

    private var suggestions: PageSuggestionModel { page.suggestions }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(suggestions.pending) { item in
                    let source = canvas.visibleRect(forPageRect: item.anchor)
                    SourceOutline()
                        .frame(width: max(24, source.width + 12), height: max(24, source.height + 12))
                        .offset(x: source.minX - 6, y: source.minY - 6)
                        .transition(.opacity)
                    PendingChip(
                        item: item,
                        replace: { replace(item, with: item.cleanText) },
                        edit: { editText = item.cleanText; editing = item },
                        addNote: { suggestions.accept(item.id) },
                        skip: { withAnimation(Theme.Motion.list) { suggestions.dismiss(item.id) } },
                        select: { index in withAnimation(Theme.Motion.quick) { suggestions.select(index, for: item.id) } }
                    )
                    .position(in: proxy.size, below: source)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }

                if let note = recentReplacement {
                    ReplacedChip(
                        restore: {
                            if page.restoreOriginal(note.id) { canvas.applyDrawing(page.drawing, actionName: "Restore handwriting") }
                            recent = nil
                        },
                        delete: {
                            page.deleteReplacement(note.id)
                            canvas.applyDrawing(page.drawing, actionName: "Delete replacement")
                            recent = nil
                        }
                    )
                    .position(in: proxy.size, below: canvas.visibleRect(forPageRect: note.anchor))
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                }

                // Text notes saved before replacements existed stay readable and removable.
                ForEach(legacyNotes) { note in
                    LegacyNoteChip(note: note) { suggestions.remove(note.id) }
                        .position(in: proxy.size, below: canvas.visibleRect(forPageRect: note.anchor))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let line = statusLine {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .panel(radius: 10)
                        .padding(12)
                        .padding(.top, topInset)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                        .accessibilityIdentifier("suggestionStatus")
                }
            }
            .animation(Theme.Motion.list, value: suggestions.pending.map(\.id))
            .animation(Theme.Motion.list, value: recentReplacement?.id)
            .animation(Theme.Motion.quick, value: statusLine)
        }
        .alert("Edit replacement", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Replace with", text: $editText)
                .accessibilityIdentifier("replacementText")
            Button("Replace") {
                if let editing { replace(editing, with: editText) }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("This text is written in place of the highlighted strokes.")
        }
    }

    private func replace(_ item: PendingSuggestion, with text: String) {
        guard page.replaceSuggestion(item.id, with: text),
              let note = page.latestVisibleReplacement else { return }
        canvas.applyDrawing(page.drawing)
        recent = (note.id, page.drawing.strokes.count)
    }

    private var recentReplacement: AcceptedAnnotation? {
        guard let recent, page.drawing.strokes.count == recent.strokes,
              let note = page.latestVisibleReplacement, note.id == recent.id else { return nil }
        return note
    }

    private var legacyNotes: [AcceptedAnnotation] {
        suggestions.annotations.filter { $0.replacement == nil && PageSuggestionModel.isVisible($0, in: page.drawing) }
    }

    private var statusLine: String? {
        if let problem = suggestions.storageProblem { return problem }
        return switch suggestions.status {
        case .idle, .checking: nil
        case .message(let text): text
        }
    }
}

/// A dashed frame around the strokes a suggestion will replace. Never intercepts the Pencil.
private struct SourceOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PendingChip: View {
    let item: PendingSuggestion
    let replace: () -> Void
    let edit: () -> Void
    let addNote: () -> Void
    let skip: () -> Void
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                // What Replace would write, or (when ink can't be replaced) exactly what "Add as note" saves.
                Text(item.allowsInkReplacement ? item.cleanText : item.annotationText)
                    .font(Font(CleanHandwriting.font(size: 22)))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("replacementPreview")
                if let note = item.uncertaintyNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                        .accessibilityIdentifier("suggestionUncertainty")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)

            Button("Replace", action: replace)
                .buttonStyle(SolidButtonStyle())
                .disabled(item.sourceStrokeIDs.isEmpty || !item.allowsInkReplacement)
                .accessibilityLabel("Replace handwriting with \(item.cleanText)")
                .accessibilityIdentifier("replaceHandwriting")

            Menu {
                if item.hasAlternatives {
                    Section("Other readings") {
                        ForEach(Array(item.proposal.candidates.enumerated()), id: \.offset) { index, candidate in
                            Button {
                                select(index)
                            } label: {
                                if index == item.selectedIndex {
                                    Label(candidate.hanzi, systemImage: "checkmark")
                                } else {
                                    Text(candidate.hanzi)
                                }
                            }
                        }
                    }
                }
                Button("Add as note (keep ink)", systemImage: "note.text", action: addNote)
                    .accessibilityIdentifier("addSuggestionNote")
                Button("Edit…", systemImage: "pencil", action: edit)
                    .disabled(!item.allowsInkReplacement)
                Button("Skip", systemImage: "xmark", action: skip)
                    .accessibilityIdentifier("skipSuggestion")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Suggestion options")
            .accessibilityIdentifier("suggestionOptions")
        }
        .padding(4)
        .panel(radius: 14)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pendingSuggestion")
    }
}

/// Shown under a replacement right after it is made.
private struct ReplacedChip: View {
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.leading, 10)
                .accessibilityHidden(true)
            Text("Replaced")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
            Button("Restore", action: restore)
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Restore original handwriting")
                .accessibilityIdentifier("restoreReplacementInline")
            Button("Delete", role: .destructive, action: delete)
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Delete replacement")
                .accessibilityIdentifier("deleteReplacementInline")
        }
        .padding(4)
        .panel(radius: 14)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

private struct LegacyNoteChip: View {
    let note: AcceptedAnnotation
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(note.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            Button("Remove note", systemImage: "xmark", role: .destructive, action: remove)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .panel(radius: 10)
        .accessibilityIdentifier("acceptedAnnotation")
    }
}

private extension View {
    /// Places the view's leading edge at the source's left edge and its top just under the source,
    /// kept inside `container` horizontally. Hidden, and not hit-testable, while scrolled away.
    func position(in container: CGSize, below source: CGRect) -> some View {
        modifier(BelowSource(container: container, source: source))
    }
}

private struct BelowSource: ViewModifier {
    let container: CGSize
    let source: CGRect
    @State private var size = CGSize(width: 240, height: 44)

    func body(content: Content) -> some View {
        let x = min(max(source.minX, 8), max(8, container.width - size.width - 8))
        let y = source.maxY + 10
        let offscreen = y + size.height < 0 || y > container.height
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: x, y: y)
            .opacity(offscreen ? 0 : 1)
            .allowsHitTesting(!offscreen)
    }
}
