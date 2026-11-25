import PencilKit
import SwiftUI
import UIKit

/// Runs the recognition feasibility check on the current page and shows what came back.
struct RecognitionCheckView: View {
    let drawing: PKDrawing

    @Environment(\.dismiss) private var dismiss
    @State private var report: RecognitionReport?
    @State private var fallbackText: String?
    @State private var fallbackElapsed: Duration?
    @AppStorage("JibijiUsePaddlePipeline") private var usePaddlePipeline = false
    @State private var paddleReport: String?
    @State private var paddleRunning = false
    @State private var query = ""
    @State private var searchResult: String?
    @State private var copied = false
    #if DEBUG
    @State private var visionResult: VisionStandaloneResult?
    @State private var visionRunning = false
    @State private var pinyinResult: PinyinOCRResult?
    @State private var pinyinMobileResult: PinyinOCRResult?
    @State private var pinyinRegions: [String]?
    @State private var pinyinRunning = false
    @State private var contextRunning = false
    /// Bumped whenever the ink changes, so a result for older ink is dropped.
    @State private var pinyinGeneration = 0
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Build") { Text(BuildStamp.summary).font(.footnote.monospaced()).textSelection(.enabled) }
                Section("PaddleOCR v6 · on-device preview") {
                    if PaddleTextPipeline.isInstalled {
                        Button(paddleRunning ? "Comparing…" : "Compare v6 reading") {
                            paddleRunning = true
                            Task {
                                let clock = ContinuousClock()
                                let start = clock.now
                                do {
                                    let lines = try await PaddleTextPipeline.shared.lines(in: drawing)
                                    let text = lines.isEmpty ? "No confident reading found." : lines.map(\.text).joined(separator: "\n")
                                    paddleReport = "\(text)\n\nElapsed: \(RecognitionReport.format(clock.now - start))"
                                } catch { paddleReport = error.localizedDescription }
                                paddleRunning = false
                            }
                        }
                        .disabled(paddleRunning)
                        .accessibilityIdentifier("comparePaddlePipeline")
                        if let paddleReport { Text(paddleReport).textSelection(.enabled) }
                        Toggle("Use v6 for suggestions and cards", isOn: $usePaddlePipeline)
                            .accessibilityIdentifier("usePaddlePipeline")
                        Text("Preview: detects text regions before reading them. Compare against your ink; it can still miss or misread handwriting. Turn this off to return to automatic recognition.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("The v6 model pack is not installed.")
                        if usePaddlePipeline {
                            Button("Return to automatic recognition") { usePaddlePipeline = false }
                        }
                    }
                }
                if let report {
                    if !report.supportsSimplifiedChinese {
                        Section(usePaddlePipeline ? "Automatic reader · comparison" : "Chinese image recognition · used by Suggestions") {
                            Text(fallbackText ?? "Reading Chinese and English ink…")
                                .textSelection(.enabled)
                            if let elapsed = fallbackElapsed {
                                LabeledContent("Latency", value: RecognitionReport.format(elapsed))
                            }
                            Text("The stroke recognizer below cannot read Chinese on this device. Suggestions and cards use on-device image recognition instead. Readings still need your confirmation.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
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
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .tint(.primary)
            .navigationTitle("Recognition check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = reportText
                        copied = true
                    }
                    .disabled(report == nil)
                }
            }
            .task {
                report = await RecognitionProbe.run(on: drawing)
                if report?.supportsSimplifiedChinese == false {
                    let clock = ContinuousClock()
                    let start = clock.now
                    do {
                        let lines = try await VisionInkReader.shared.lines(in: drawing)
                        fallbackText = lines.isEmpty ? "No clear reading found." : lines.map(\.text).joined(separator: "\n")
                    } catch { fallbackText = "Recognition failed: \(error.localizedDescription)" }
                    fallbackElapsed = clock.now - start
                }
            }
            #if DEBUG
            .onChange(of: drawing.dataRepresentation()) {
                pinyinGeneration += 1
                pinyinResult = nil
                pinyinMobileResult = nil
                pinyinRegions = nil
                pinyinRunning = false
                contextRunning = false
            }
            #endif
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
            #if DEBUG
            if let pinyinCheck = report.pinyinCheck {
                Section("Pinyin handwriting check (DEBUG)") {
                    ForEach(pinyinCheck.lines, id: \.self) { Text($0).textSelection(.enabled) }
                }
                .accessibilityIdentifier("pinyinCheck")
            }
            visionSection
            pinyinSection
            #endif
            if #available(iOS 27.0, *) {
                searchSection
            }
        }
    }

    /// Copyable report: the unchanged baseline summary, plus the Vision comparison once it has run.
    private var reportText: String? {
        guard let summary = report?.summary else { return nil }
        #if DEBUG
        var text = summary
        if let visionResult {
            text += "\nVision standalone Pinyin comparison (DEBUG, opt-in):\n"
                + visionResult.lines.map { "  " + $0 }.joined(separator: "\n")
        }
        if let pinyinResult {
            text += "\nStandalone Pinyin OCR, PP-OCRv5 ONNX (DEBUG, opt-in):\n"
                + pinyinResult.lines.map { "  " + $0 }.joined(separator: "\n")
        }
        if let pinyinMobileResult {
            text += "\nPaddleOCR mobile (ink cleanup), PP-OCRv5 mobile ONNX (DEBUG, opt-in):\n"
                + pinyinMobileResult.lines.map { "  " + $0 }.joined(separator: "\n")
        }
        if let pinyinRegions {
            text += "\nContext-aware Pinyin routing (DEBUG, opt-in; targeted Paddle only, PencilKit raw kept):\n"
                + pinyinRegions.map { "  " + $0 }.joined(separator: "\n")
        }
        return text
        #else
        return summary
        #endif
    }

    #if DEBUG
    private var visionSection: some View {
        Section {
            Button(visionRunning ? "Running Vision…" : "Run Vision on full drawing", action: runVision)
                .disabled(visionRunning)
                .accessibilityIdentifier("runVisionComparison")
            if visionRunning {
                ProgressView()
            }
            if let visionResult {
                ForEach(Array(visionResult.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled)
                }
                .accessibilityIdentifier("visionResult")
            }
        } header: {
            Text("Vision comparison (DEBUG, opt-in)")
        } footer: {
            Text("Separate from the PencilKit result above. Renders a temporary black-on-white copy of the ink; nothing is saved or changed.")
        }
    }

    private func runVision() {
        guard !visionRunning else { return }
        visionRunning = true
        let drawing = drawing
        copied = false
        Task {
            let result = await RecognitionProbe.visionStandaloneCheck(on: drawing)
            visionResult = result
            visionRunning = false
            copied = false
        }
    }

    private var pinyinSection: some View {
        Section {
            Button(pinyinRunning ? "Running Pinyin OCR…" : "Run Pinyin OCR by line", action: runPinyin)
                .disabled(pinyinRunning)
                .accessibilityIdentifier("runPinyinOCR")
            if pinyinRunning {
                ProgressView()
            }
            if let pinyinResult {
                ForEach(Array(pinyinResult.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled)
                }
                .accessibilityIdentifier("pinyinOCRResult")
            }
            if let pinyinMobileResult {
                Text("PaddleOCR mobile (ink cleanup)").font(.headline)
                ForEach(Array(pinyinMobileResult.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled)
                }
                .accessibilityIdentifier("pinyinMobileOCRResult")
            }
            Button(contextRunning ? "Running context routing…" : "Run context-aware routing (targeted Paddle only)", action: runContextRouting)
                .disabled(contextRunning)
                .accessibilityIdentifier("runPinyinContextRouting")
            if let pinyinRegions {
                Text("Context-aware routing (targeted Paddle only)").font(.headline)
                ForEach(Array(pinyinRegions.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled)
                }
                .accessibilityIdentifier("pinyinRegionResult")
            }
        } header: {
            Text("Standalone Pinyin OCR (DEBUG, opt-in)")
        } footer: {
            Text("Pinyin OCR by line: clearly separated horizontal lines of writing are cropped and read one at a time, top to bottom (otherwise the whole drawing is one line). Runs local PP-OCRv5 models on temporary black-on-white copies; raw output, nothing is saved or changed.")
        }
    }

    private func runPinyin() {
        guard !pinyinRunning else { return }
        pinyinRunning = true
        copied = false
        let generation = pinyinGeneration
        let drawing = drawing
        Task {
            let result = await PinyinOCR.shared.recognize(drawing)
            let mobile = await PinyinOCR.shared.recognizeMobile(drawing)
            guard generation == pinyinGeneration else { return }
            pinyinResult = result
            pinyinMobileResult = mobile
            pinyinRunning = false
            copied = false
        }
    }

    private func runContextRouting() {
        guard !contextRunning else { return }
        contextRunning = true
        copied = false
        let generation = pinyinGeneration
        let drawing = drawing
        Task {
            let lines = await PinyinContextRouting.run(on: drawing)
            guard generation == pinyinGeneration else { return }
            pinyinRegions = lines
            contextRunning = false
            copied = false
        }
    }
    #endif

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
