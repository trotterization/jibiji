import PencilKit
import SwiftUI

/// Draws provisional suggestions and accepted notes just below their source ink. It has the same
/// frame as the canvas and follows its scroll offset; it never draws over the ink itself, and empty
/// areas let Pencil and touches through to the canvas.
struct SuggestionOverlay: View {
    let suggestions: PageSuggestionModel
    /// The page's current ink; notes whose source ink is erased are hidden, and return if it is restored.
    let drawing: PKDrawing
    let canvas: CanvasController

    @State private var editing: PendingSuggestion?
    @State private var editText = ""

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let line = statusLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("suggestionStatus")
                }
                ForEach(visibleNotes) { note in
                    AcceptedChip(note: note) { suggestions.remove(note.id) }
                        .position(in: proxy.size, below: canvas.visibleRect(forPageRect: note.anchor))
                }
                ForEach(suggestions.pending) { item in
                    PendingChip(
                        item: item,
                        accept: { suggestions.accept(item.id) },
                        dismiss: { suggestions.dismiss(item.id) },
                        edit: { editText = item.annotationText; editing = item },
                        select: { suggestions.select($0, for: item.id) }
                    )
                    .position(in: proxy.size, below: canvas.visibleRect(forPageRect: item.anchor), offsetRows: stackedOffset(for: item))
                }
            }
        }
        .alert("Edit note", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Note", text: $editText)
            Button("Add") {
                if let editing { suggestions.accept(editing.id, editedText: editText) }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("Your wording is added beside the ink. The ink is not changed.")
        }
    }

    private var statusLine: String? {
        if let problem = suggestions.storageProblem { return problem }
        switch suggestions.status {
        case .idle: return nil
        case .checking: return "Reading your writing…"
        case .message(let text): return text
        }
    }

    /// A pending chip sits below any accepted note on the same line.
    private func stackedOffset(for item: PendingSuggestion) -> Int {
        visibleNotes.filter { $0.anchor.intersects(item.anchor) }.count
    }

    private var visibleNotes: [AcceptedAnnotation] {
        suggestions.annotations.filter { PageSuggestionModel.isVisible($0, in: drawing) }
    }
}

private extension View {
    /// Places the view's leading edge at the source's left edge and its top just under the source,
    /// kept inside `container` horizontally.
    func position(in container: CGSize, below source: CGRect, offsetRows: Int = 0) -> some View {
        modifier(BelowSource(container: container, source: source, rows: offsetRows))
    }
}

private struct BelowSource: ViewModifier {
    let container: CGSize
    let source: CGRect
    let rows: Int
    @State private var size = CGSize(width: 220, height: 32)

    func body(content: Content) -> some View {
        let x = min(max(source.minX, 8), max(8, container.width - size.width - 8))
        let y = source.maxY + 6 + CGFloat(rows) * (size.height + 4)
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: x, y: y)
            // Off-screen chips (scrolled away) aren't built into the hit-testing area.
            .opacity(y + size.height < 0 || y > container.height ? 0 : 1)
            .allowsHitTesting(!(y + size.height < 0 || y > container.height))
    }
}

private struct PendingChip: View {
    let item: PendingSuggestion
    let accept: () -> Void
    let dismiss: () -> Void
    let edit: () -> Void
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: accept) {
                Text(item.annotationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .padding(.vertical, 6)
            }
            .accessibilityLabel("Accept suggestion \(item.annotationText)")
            .accessibilityIdentifier("acceptSuggestion")
            Menu {
                Button("Accept", systemImage: "checkmark", action: accept)
                Button("Edit…", systemImage: "pencil", action: edit)
                if item.hasAlternatives {
                    Section("Alternatives") {
                        ForEach(Array(item.proposal.candidates.enumerated()), id: \.offset) { index, candidate in
                            Button {
                                select(index)
                            } label: {
                                if index == item.selectedIndex {
                                    Label("\(candidate.hanzi) \(candidate.pinyin) · \(candidate.gloss)", systemImage: "checkmark")
                                } else {
                                    Text("\(candidate.hanzi) \(candidate.pinyin) · \(candidate.gloss)")
                                }
                            }
                        }
                    }
                }
                Button("Dismiss", systemImage: "xmark", role: .destructive, action: dismiss)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Suggestion options")
            .accessibilityIdentifier("suggestionOptions")
        }
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .accessibilityIdentifier("pendingSuggestion")
    }
}

private struct AcceptedChip: View {
    let note: AcceptedAnnotation
    let remove: () -> Void

    var body: some View {
        Text(note.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .contextMenu { Button("Remove note", systemImage: "trash", role: .destructive, action: remove) }
            .accessibilityIdentifier("acceptedAnnotation")
    }
}
