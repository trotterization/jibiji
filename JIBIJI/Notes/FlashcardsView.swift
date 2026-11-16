import SwiftUI
import UniformTypeIdentifiers

/// UTF-8 plain-text document for Quizlet import.
struct QuizletTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Review, study, and export this page's flashcards. Everything stays on device.
struct FlashcardsView: View {
    let page: NotePageModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PageFlashcard?
    @State private var studying = false
    @State private var exporting = false
    @State private var copied = false

    private var deck: PageFlashcards { page.flashcards }

    private var staleCards: [PageFlashcard] {
        deck.cards.filter { $0.status != .discarded && !deck.isCurrent($0) }
    }

    private var discardedCurrent: [PageFlashcard] {
        deck.cards.filter { $0.status == .discarded && deck.isCurrent($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Generate from page", systemImage: "wand.and.stars") {
                        page.saveIfNeeded()
                        deck.refresh(from: page.drawing, annotations: page.suggestions.annotations)
                    }
                    .disabled(deck.status == .reading)
                    .accessibilityIdentifier("generateCards")
                    if deck.status == .reading {
                        HStack { ProgressView(); Text("Reading page…") }
                    } else if case .message(let text) = deck.status {
                        Text(text).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Drafts (current page)") {
                    if deck.currentDrafts.isEmpty { Text("No drafts").foregroundStyle(.secondary) }
                    ForEach(deck.currentDrafts) { card in
                        cardRow(card)
                        HStack {
                            Button("Edit") { editing = card }
                            Button("Approve") { deck.approve(card.id) }
                                .disabled(card.front.isBlank || card.back.isBlank)
                            Button("Discard", role: .destructive) { deck.discard(card.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Approved (current page)") {
                    if deck.approvedCurrent.isEmpty { Text("No approved cards").foregroundStyle(.secondary) }
                    ForEach(deck.approvedCurrent) { card in
                        cardRow(card)
                        HStack {
                            Button("Edit") { editing = card }
                            Button("Back to draft") { deck.restoreToDraft(card.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !staleCards.isEmpty {
                    Section {
                        ForEach(staleCards) { card in
                            cardRow(card)
                            HStack {
                                Button("Discard", role: .destructive) { deck.discard(card.id) }
                            }
                            .buttonStyle(.bordered)
                        }
                    } header: {
                        Text("Stale")
                    } footer: {
                        Text("The page changed after these were made. They aren't studied or exported. Generate again to refresh matching cards.")
                    }
                }

                if !discardedCurrent.isEmpty {
                    Section("Discarded") {
                        ForEach(discardedCurrent) { card in
                            cardRow(card)
                            Button("Restore to draft") { deck.restoreToDraft(card.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Study & export") {
                    Button("Study approved cards", systemImage: "rectangle.stack") { studying = true }
                        .disabled(deck.approvedCurrent.isEmpty)
                    Button(copied ? "Copied" : "Copy Quizlet text", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = deck.quizletExport
                        copied = true
                    }
                    .disabled(deck.approvedCurrent.isEmpty)
                    Button("Export .txt file", systemImage: "square.and.arrow.up") { exporting = true }
                        .disabled(deck.approvedCurrent.isEmpty)
                }
            }
            .onAppear { deck.invalidateRemovedCorrections(activeIDs: Set(page.suggestions.annotations.map(\.id))) }
            .navigationTitle("Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { card in
                EditCardView(card: card) { front, back in deck.edit(card.id, front: front, back: back) }
            }
            .sheet(isPresented: $studying) { StudyView(cards: deck.approvedCurrent) }
            .fileExporter(
                isPresented: $exporting,
                document: QuizletTextDocument(data: deck.quizletData),
                contentType: .plainText,
                defaultFilename: "\(page.pageID)-quizlet"
            ) { _ in }
            .onChange(of: deck.approvedCurrent) { copied = false }
        }
    }

    private func cardRow(_ card: PageFlashcard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.front).font(.headline)
            Text(card.back)
            Text("From: \(card.sourceText)")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(page.pageID) · line \(Int(card.sourceBounds.minX)),\(Int(card.sourceBounds.minY))")
                .font(.caption2).foregroundStyle(.secondary)
            if card.needsReview { Label("Needs review", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if card.edited { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct EditCardView: View {
    let card: PageFlashcard
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var front: String
    @State private var back: String

    init(card: PageFlashcard, onSave: @escaping (String, String) -> Void) {
        self.card = card
        self.onSave = onSave
        _front = State(initialValue: card.front)
        _back = State(initialValue: card.back)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Front") { TextField("Front", text: $front, axis: .vertical) }
                Section("Back") { TextField("Back", text: $back, axis: .vertical) }
                Section("Source") { Text(card.sourceText).foregroundStyle(.secondary) }
            }
            .navigationTitle("Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(front, back); dismiss() }
                }
            }
        }
    }
}

private struct StudyView: View {
    let cards: [PageFlashcard]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var flipped = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if cards.indices.contains(index) {
                    let card = cards[index]
                    Text("\(index + 1) of \(cards.count)").font(.caption).foregroundStyle(.secondary)
                    Text(flipped ? card.back : card.front)
                        .font(.largeTitle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { flipped.toggle() }
                    HStack {
                        Button("Flip") { flipped.toggle() }
                        Button("Next") {
                            index = (index + 1) % cards.count
                            flipped = false
                        }
                        .disabled(cards.count < 2)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("No approved cards").foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
