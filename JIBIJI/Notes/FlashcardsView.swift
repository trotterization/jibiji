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
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    generate.rises()

                    section("Drafts (current page)", count: deck.currentDrafts.count) {
                        if deck.currentDrafts.isEmpty { emptyRow("No drafts") }
                        ForEach(deck.currentDrafts) { card in
                            cardTile(card) {
                                Button("Approve") { deck.approve(card.id) }
                                    .buttonStyle(SolidButtonStyle())
                                    .disabled(card.front.isBlank || card.back.isBlank)
                                Button("Edit") { editing = card }
                                Button("Discard", role: .destructive) { deck.discard(card.id) }
                            }
                        }
                    }
                    .rises(after: 0.06)

                    section("Approved (current page)", count: deck.approvedCurrent.count) {
                        if deck.approvedCurrent.isEmpty { emptyRow("No approved cards") }
                        ForEach(deck.approvedCurrent) { card in
                            cardTile(card) {
                                Button("Edit") { editing = card }
                                Button("Back to draft") { deck.restoreToDraft(card.id) }
                            }
                        }
                    }
                    .rises(after: 0.12)

                    if !staleCards.isEmpty {
                        section("Stale", count: staleCards.count) {
                            ForEach(staleCards) { card in
                                cardTile(card) {
                                    Button("Discard", role: .destructive) { deck.discard(card.id) }
                                }
                            }
                            Text("The page changed after these were made. They aren't studied or exported. Generate again to refresh matching cards.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                        .transition(.opacity)
                    }

                    if !discardedCurrent.isEmpty {
                        section("Discarded", count: discardedCurrent.count) {
                            ForEach(discardedCurrent) { card in
                                cardTile(card) {
                                    Button("Restore to draft") { deck.restoreToDraft(card.id) }
                                }
                                .opacity(0.72)
                            }
                        }
                        .transition(.opacity)
                    }

                    section("Study & export", count: nil) { studyAndExport }
                        .rises(after: 0.18)
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .animation(Theme.Motion.list, value: deck.cards)
                .animation(Theme.Motion.list, value: deck.status)
            }
            .background(Theme.surface)
            .tint(.primary)
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

    private var generate: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                page.saveIfNeeded()
                deck.refresh(from: page.drawing, annotations: page.suggestions.annotations)
            } label: {
                HStack {
                    Text("Generate from page")
                    Spacer()
                    if deck.status == .reading {
                        ProgressView().controlSize(.small).tint(Theme.onInk).transition(.opacity)
                    } else {
                        Image(systemName: "arrow.right").transition(.opacity)
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onInk)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.985))
            .disabled(deck.status == .reading)
            .accessibilityIdentifier("generateCards")
            if deck.status == .reading {
                Text("Reading page…")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            } else if case .message(let text) = deck.status {
                Text(text)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
    }

    private var studyAndExport: some View {
        VStack(spacing: 0) {
            actionRow("Study approved cards", systemImage: "rectangle.stack") { studying = true }
            Divider().overlay(Theme.hairline).padding(.leading, 18)
            actionRow(copied ? "Copied" : "Copy Quizlet text", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = deck.quizletExport
                withAnimation(Theme.Motion.quick) { copied = true }
            }
            Divider().overlay(Theme.hairline).padding(.leading, 18)
            actionRow("Export .txt file", systemImage: "square.and.arrow.up") { exporting = true }
        }
        .panel()
        .disabled(deck.approvedCurrent.isEmpty)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).contentTransition(.opacity)
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private func section(_ title: String, count: Int?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .transition(.opacity)
    }

    private func cardTile(_ card: PageFlashcard, @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardRow(card)
            HStack(spacing: 8) { actions() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .panel()
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        ))
    }

    private func cardRow(_ card: PageFlashcard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.front).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 0)
                if card.needsReview {
                    Label("Needs review", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.pending)
                }
                if card.edited { Text("Edited").font(.caption).foregroundStyle(.secondary) }
            }
            Text(card.back).font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text("From: \(card.sourceText)")
                Text("\(page.pageID) · line \(Int(card.sourceBounds.minX)),\(Int(card.sourceBounds.minY))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}

/// A full-width row inside a panel: darkens while pressed, dims when disabled.
private struct RowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(Color.primary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.05 : 0))
            .opacity(isEnabled ? 1 : 0.35)
            .animation(Theme.Motion.press, value: configuration.isPressed)
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
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .tint(.primary)
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
                    VStack(spacing: 10) {
                        Text("\(index + 1) of \(cards.count)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        GeometryReader { proxy in
                            Capsule().fill(Theme.hairline)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.primary)
                                        .frame(width: proxy.size.width * CGFloat(index + 1) / CGFloat(cards.count))
                                }
                        }
                        .frame(width: 160, height: 3)
                        .accessibilityHidden(true)
                    }
                    FlipCard(angle: flipped ? 180 : 0, front: card.front, back: card.back)
                        .frame(maxWidth: 560, maxHeight: 380)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { flip() }
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .offset(x: 60).combined(with: .opacity),
                            removal: .offset(x: -60).combined(with: .opacity)
                        ))
                    HStack(spacing: 10) {
                        Button("Flip") { flip() }
                            .buttonStyle(QuietButtonStyle())
                        Button("Next") {
                            withAnimation(Theme.Motion.list) {
                                index = (index + 1) % cards.count
                                flipped = false
                            }
                        }
                        .buttonStyle(SolidButtonStyle())
                        .disabled(cards.count < 2)
                    }
                } else {
                    Text("No approved cards").foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
            .tint(.primary)
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func flip() {
        withAnimation(.spring(duration: 0.55, bounce: 0.18)) { flipped.toggle() }
    }
}

/// A card that turns over around its vertical axis. The face changes as it passes edge-on.
private struct FlipCard: View, @preconcurrency Animatable {
    var angle: Double
    let front: String
    let back: String

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showsBack = angle > 90
        Text(showsBack ? back : front)
            .font(.system(size: showsBack ? 30 : 44, weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel(radius: 24)
            .shadow(color: .black.opacity(0.06), radius: 24, y: 12)
            // Un-mirror the back face.
            .scaleEffect(x: showsBack ? -1 : 1)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
    }
}
