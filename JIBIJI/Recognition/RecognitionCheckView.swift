import PencilKit
import SwiftUI
import UIKit

/// Runs the recognition feasibility check on the current page and shows what came back.
struct RecognitionCheckView: View {
    let drawing: PKDrawing

    @Environment(\.dismiss) private var dismiss
    @State private var report: RecognitionReport?
    @State private var query = ""
    @State private var searchResult: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if let report {
                    results(report)
                } else {
                    ProgressView("Recognizing ink…")
                        .frame(maxWidth: .infinity)
                }
                Section {
                    Text("Use synthetic notes only, such as “fùzé” beside “responsible for?”. Don't test with private classroom pages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Recognition check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = report?.summary
                        copied = true
                    }
                    .disabled(report == nil)
                }
            }
            .task {
                report = await RecognitionProbe.run(on: drawing)
            }
        }
    }

    @ViewBuilder
    private func results(_ report: RecognitionReport) -> some View {
        switch report.availability {
        case .unavailable(let reason):
            Section("PKStrokeRecognizer") {
                LabeledContent("Status", value: "Unavailable")
                Text(reason)
                LabeledContent("OS", value: report.osVersion)
            }
            .accessibilityIdentifier("recognizerUnavailable")
        case .available:
            Section("Recognized text") {
                Text(report.recognizedText ?? "No text recognized")
                    .font(.title3)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("recognizedText")
                LabeledContent("Strokes", value: "\(report.strokeCount)")
                LabeledContent("Latency", value: report.elapsed.map(RecognitionReport.format) ?? "–")
            }
            Section("PKStrokeRecognizer") {
                LabeledContent("Status", value: "Available")
                    .accessibilityIdentifier("recognizerAvailable")
                LabeledContent("Recognition version", value: report.recognitionVersion.map(String.init) ?? "–")
                LabeledContent("Simplified Chinese", value: report.supportsSimplifiedChinese ? "Supported" : "Not supported")
                LabeledContent("Active languages", value: report.activeLanguages.joined(separator: ", "))
                LabeledContent("OS", value: report.osVersion)
                DisclosureGroup("All supported languages (\(report.supportedLanguages.count))") {
                    Text(report.supportedLanguages.joined(separator: ", "))
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            if #available(iOS 27.0, *) {
                searchSection
            }
        }
    }

    @available(iOS 27.0, *)
    private var searchSection: some View {
        Section {
            HStack {
                TextField("Search the ink, e.g. 负责", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(runSearch)
                Button("Search", action: runSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let searchResult {
                Text(searchResult)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Find in ink")
        } footer: {
            Text("Shows which strokes and page region match, the references inline suggestions would anchor to.")
        }
    }

    @available(iOS 27.0, *)
    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            let matches = await RecognitionProbe.search(text, in: drawing)
            searchResult = matches.isEmpty
                ? "No matches for “\(text)”."
                : matches.enumerated().map { index, match in
                    let b = match.bounds.integral
                    return "Match \(index + 1): \(match.strokeIDs.count) strokes at x \(Int(b.minX)), y \(Int(b.minY)), \(Int(b.width))×\(Int(b.height)) pt"
                }.joined(separator: "\n")
        }
    }
}
