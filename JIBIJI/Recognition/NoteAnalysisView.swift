#if DEBUG
import PencilKit
import SwiftUI
import UIKit

/// Debug-only Note Analysis. Opens already analyzing the current page: no buttons to press. Shows what was
/// recognized per field, where on the page it came from, what is missing, tentative suggestions and
/// uncertainty, plus the page's existing flashcards. Read-only: the drawing and cards are never changed here.
struct NoteAnalysisView: View {
    let page: NotePageModel

    @Environment(\.dismiss) private var dismiss
    @State private var analysis: NoteAnalysis?
    @State private var copied = false
    @State private var showsCards = false

    private var drawing: PKDrawing { page.drawing }

    var body: some View {
        NavigationStack {
            List {
                if let analysis {
                    summary(analysis)
                    if !analysis.errors.isEmpty { errors(analysis) }
                    pageMap(analysis)
                    entries(analysis)
                    cells(analysis)
                } else {
                    ProgressView("Analyzing ink…").frame(maxWidth: .infinity)
                }
                cards
                Section {
                    Text("Use synthetic notes only. Nothing here changes your ink or cards.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Note analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") {
                        if let analysis {
                            UIPasteboard.general.string = NoteAnalyzer.reportText(analysis)
                            copied = true
                        }
                    }
                    .disabled(analysis == nil)
                    .accessibilityIdentifier("copyAnalysisReport")
                }
            }
            // Runs when the screen opens, and again if the ink somehow changes underneath it.
            .task(id: PageFlashcards.digest(of: drawing)) {
                analysis = nil
                copied = false
                let result = await NoteAnalyzer.analyze(drawing)
                if !Task.isCancelled { analysis = result }
            }
            .sheet(isPresented: $showsCards) { FlashcardsView(page: page) }
        }
    }

    // MARK: - Sections

    private func summary(_ analysis: NoteAnalysis) -> some View {
        Section("Summary") {
            LabeledContent("Entries", value: "\(analysis.entries.count)")
                .accessibilityIdentifier("analysisEntryCount")
            LabeledContent("Strokes · rows · cells", value: "\(analysis.strokeCount) · \(analysis.rows.count) · \(analysis.cells.count)")
            LabeledContent("Reading time", value: RecognitionReport.format(analysis.readTime))
            LabeledContent("Total time", value: RecognitionReport.format(analysis.totalTime))
            LabeledContent("OS", value: analysis.osVersion)
        }
        .accessibilityIdentifier("analysisDone")
    }

    private func errors(_ analysis: NoteAnalysis) -> some View {
        Section("Problems") {
            ForEach(analysis.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }

    @ViewBuilder
    private func pageMap(_ analysis: NoteAnalysis) -> some View {
        if !analysis.entries.isEmpty, let map = PageMap(drawing: drawing, analysis: analysis) {
            Section("Source regions") {
                map
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Page with a colored box around each entry")
            }
        }
    }

    private func entries(_ analysis: NoteAnalysis) -> some View {
        Section("Entries") {
            if analysis.entries.isEmpty {
                Text(analysis.strokeCount == 0 ? "The page is blank." : "No entries found.").foregroundStyle(.secondary)
            }
            ForEach(Array(analysis.entries.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Label("Entry \(index + 1) · \(item.entry.arrangement.rawValue)", systemImage: "square.dashed")
                        .font(.headline)
                        .foregroundStyle(PageMap.color(index))
                    ForEach(NoteGrouping.FieldKind.allCases, id: \.self) { kind in
                        if let field = item.entry.field(kind) {
                            LabeledContent(kind.rawValue) { Text(field.text).textSelection(.enabled) }
                        } else {
                            LabeledContent(kind.rawValue) { Text("missing").foregroundStyle(.red) }
                        }
                    }
                    if let suggestion = item.suggestion { suggestionView(suggestion) }
                    ForEach(item.uncertainty, id: \.self) {
                        Label($0, systemImage: "questionmark.circle").font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("analysisEntry\(index + 1)")
            }
        }
    }

    private func suggestionView(_ suggestion: NoteSuggestion) -> some View {
        let candidate = suggestion.candidate
        return VStack(alignment: .leading, spacing: 2) {
            Label("Tentative: \(candidate.hanzi) (\(candidate.pinyin)) “\(candidate.gloss)”", systemImage: "sparkles")
                .font(.subheadline)
            Text("Would add: \(suggestion.fills.map(\.rawValue).joined(separator: ", ")). Provisional; nothing is accepted.")
                .font(.footnote).foregroundStyle(.secondary)
            if !suggestion.alternatives.isEmpty {
                Text("Alternatives: " + suggestion.alternatives.map { "\($0.hanzi) “\($0.gloss)”" }.joined(separator: "; "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func cells(_ analysis: NoteAnalysis) -> some View {
        Section {
            DisclosureGroup("Layout candidates and raw text (\(analysis.cells.count) cells)") {
                Text(NoteAnalyzer.reportText(analysis).components(separatedBy: "\nCells (layout candidates, read order)\n").last ?? "")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var cards: some View {
        Section("Flashcards (kept as they are)") {
            let deck = page.flashcards
            LabeledContent("Drafts · approved · changed ink", value: "\(deck.currentDrafts.count) · \(deck.approvedCurrent.count) · \(deck.staleCount)")
            Button("Open cards", systemImage: "rectangle.on.rectangle") {
                page.saveIfNeeded()
                showsCards = true
            }
            .accessibilityIdentifier("cardsButton")
        }
    }
}

/// The page ink with a colored box around each entry's fields.
private struct PageMap: View {
    let image: UIImage
    let origin: CGPoint
    let boxes: [(index: Int, rect: CGRect)]

    static func color(_ index: Int) -> Color {
        [.blue, .green, .orange, .purple, .pink, .teal][index % 6]
    }

    init?(drawing: PKDrawing, analysis: NoteAnalysis) {
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard !drawing.strokes.isEmpty, bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        var rendered = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = RecognitionProbe.monochromeCopy(of: drawing).image(from: bounds, scale: 1)
        }
        image = rendered
        origin = bounds.origin
        boxes = analysis.entries.enumerated().flatMap { index, item in
            item.entry.fields.map { (index, $0.bounds) }
        }
    }

    var body: some View {
        let size = image.size
        GeometryReader { proxy in
            let scale = proxy.size.width / size.width
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().background(.white)
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    Rectangle()
                        .stroke(Self.color(box.index), lineWidth: 2)
                        .frame(width: box.rect.width * scale, height: box.rect.height * scale)
                        .offset(x: (box.rect.minX - origin.x) * scale, y: (box.rect.minY - origin.y) * scale)
                }
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .frame(maxHeight: 360)
    }
}
#endif
