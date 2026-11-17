import PencilKit
import SwiftUI

/// Quiet source-region outlines open a roomy review panel. Accepted replacements
/// are native ink, so no accepted-text stickers cover the page.
struct SuggestionOverlay: View {
    let suggestions: PageSuggestionModel
    let drawing: PKDrawing
    let canvas: CanvasController
    let review: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(suggestions.pending) { item in
                    let bounds = canvas.visibleRect(forPageRect: item.anchor)
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.teal.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .background(.teal.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                    .frame(width: max(32, bounds.width + 8), height: max(32, bounds.height + 8))
                    .offset(x: bounds.minX - 4, y: bounds.minY - 4)
                    .accessibilityLabel("Review handwriting suggestion")
                    .accessibilityIdentifier("pendingSuggestion")
                }
                // Legacy annotations remain removable with a visible button.
                ForEach(suggestions.annotations.filter { $0.replacement == nil && PageSuggestionModel.isVisible($0, in: drawing) }) { note in
                    let bounds = canvas.visibleRect(forPageRect: note.anchor)
                    HStack {
                        Text(note.text).font(.callout)
                        Button("Delete", systemImage: "trash") { suggestions.remove(note.id) }
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize()
                    .offset(x: max(8, bounds.minX), y: bounds.maxY + 6)
                    .accessibilityIdentifier("acceptedAnnotation")
                }
            }
            .overlay(alignment: .topTrailing) {
                if !suggestions.pending.isEmpty {
                    Button("Review \(suggestions.pending.count) suggestions", systemImage: "hand.draw") { review() }
                        .buttonStyle(.borderedProminent)
                        .padding(12)
                } else if let statusLine {
                    Text(statusLine).font(.footnote).padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("suggestionStatus")
                }
            }
        }
    }

    private var statusLine: String? {
        if let problem = suggestions.storageProblem { return problem }
        return switch suggestions.status {
        case .idle: nil
        case .checking: "Reading your writing…"
        case .message(let text): text
        }
    }
}

struct SuggestionReviewView: View {
    let page: NotePageModel
    let canvas: CanvasController
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    @State private var replacement = ""

    private var item: PendingSuggestion? {
        let items = page.suggestions.pending
        return items.isEmpty ? nil : items[min(selection, items.count - 1)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text("\(page.suggestions.pending.count) to review").foregroundStyle(.secondary)
                            Spacer()
                            Button("Previous", systemImage: "chevron.left") { selection = max(0, selection - 1) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(selection == 0)
                            Button("Next", systemImage: "chevron.right") { selection = min(page.suggestions.pending.count - 1, selection + 1) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(selection >= page.suggestions.pending.count - 1)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading) {
                                Text("Your writing").font(.caption).foregroundStyle(.secondary)
                                Image(uiImage: sourceImage(item)).resizable().scaledToFit().frame(maxWidth: .infinity, minHeight: 100, maxHeight: 130)
                            }
                            VStack(alignment: .leading) {
                                Text("Clean handwriting").font(.caption).foregroundStyle(.secondary)
                                Text(replacement).font(Font(CleanHandwriting.font(size: 46)))
                                    .minimumScaleFactor(0.3).lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 130)
                                    .accessibilityIdentifier("replacementPreview")
                            }
                        }
                        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        TextField("Replace with…", text: $replacement)
                            .font(.title3).padding(14)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("replacementText")
                        if item.hasAlternatives {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Other readings").font(.caption).foregroundStyle(.secondary)
                                ScrollView(.horizontal) {
                                    HStack {
                                        ForEach(Array(item.proposal.candidates.enumerated()), id: \.offset) { index, candidate in
                                            Button(candidate.hanzi) {
                                                page.suggestions.select(index, for: item.id)
                                                replacement = page.suggestions.pending.first { $0.id == item.id }?.replacementText ?? candidate.hanzi
                                            }
                                            .font(Font(CleanHandwriting.font(size: 28)))
                                            .padding(.horizontal, 16).frame(minHeight: 48)
                                            .background(item.selectedIndex == index ? Color.teal.opacity(0.18) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                        }
                                    }
                                }
                            }
                        }
                        Text("Replaces the highlighted strokes in place. Use the eraser or lasso to edit the result, or Undo to bring your writing back.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = page.suggestions.storageProblem { Text(error).foregroundStyle(.red) }
                        if item.sourceStrokeIDs.isEmpty {
                            Text("Couldn't locate the strokes for this reading. Skip it and try reading the page again.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .task(id: item.id) { replacement = item.replacementText }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if let item {
                        HStack(spacing: 12) {
                            Button("Skip") {
                                page.suggestions.dismiss(item.id)
                                selection = min(selection, max(0, page.suggestions.pending.count - 1))
                                closeIfFinished()
                            }
                                .buttonStyle(.bordered).controlSize(.large)
                                .accessibilityIdentifier("skipSuggestion")
                            Button("Replace handwriting", systemImage: "checkmark") {
                                if page.replaceSuggestion(item.id, with: replacement) {
                                    canvas.applyDrawing(page.drawing)
                                    selection = min(selection, max(0, page.suggestions.pending.count - 1))
                                    closeIfFinished()
                                }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.count > 200 || item.sourceStrokeIDs.isEmpty)
                            .accessibilityIdentifier("replaceHandwriting")
                        }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
            }
            .navigationTitle("Clean up handwriting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: page.suggestions.pending.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private func sourceImage(_ item: PendingSuggestion) -> UIImage {
        let strokes = page.drawing.strokes.filter { item.sourceStrokeIDs.contains(InkSelection.identity($0)) }
        let source = PKDrawing(strokes: strokes)
        let bounds = (strokes.isEmpty ? item.anchor : source.bounds).insetBy(dx: -4, dy: -4)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return UIImage() }
        return (strokes.isEmpty ? page.drawing : source).image(from: bounds, scale: 2)
    }

    private func closeIfFinished() {
        if page.suggestions.pending.isEmpty { dismiss() }
    }
}
