import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFLibraryView: View {
    let library: PDFLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if library.items.isEmpty {
                    ContentUnavailableView("Your PDFs", systemImage: "doc.richtext", description: Text("Import a textbook, paper, or planner to read and annotate."))
                }
                ForEach(library.items.filter { query.isEmpty || ($0.title + " " + $0.text).localizedStandardContains(query) }) { item in
                    NavigationLink(value: item.id) {
                        Label { VStack(alignment: .leading) {
                            Text(item.title).font(.headline)
                            Text("\(item.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: "doc.richtext") }
                    }.accessibilityIdentifier("pdfDocument-\(item.id)")
                }
                if library.importing { ProgressView("Importing PDF…") }
                if library.indexingSearch {
                    ProgressView(library.searchProgress ?? "Preparing scanned text…").accessibilityIdentifier("pdfLibraryIndexProgress")
                    Button("Stop Indexing") { library.cancelSearchIndexing() }
                } else {
                    Button("Update Search Index", systemImage: "text.viewfinder") { library.indexSearchableText() }
                }
                if library.hasPendingInk { Text("Some annotations aren't saved yet. Reopen their document to retry.").foregroundStyle(.red) }
                if let problem = library.problem { Text(problem).foregroundStyle(.red) }
            }
            .searchable(text: $query, prompt: "Search PDF titles and text")
            .navigationTitle("PDF Documents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Import PDF", systemImage: "square.and.arrow.down") { importing = true }.disabled(library.importing).accessibilityIdentifier("importPDF") }
            }
            .navigationDestination(for: UUID.self) { id in
                if let item = library.items.first(where: { $0.id == id }) { PDFDocumentScreen(item: item, library: library) }
            }
            .task {
                let work = library.indexSearchableText()
                await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { Task { _ = await library.importPDF(from: url) } }
                if case .failure(let error) = result { library.problem = error.localizedDescription }
            }
        }
    }
}

private struct PDFDocumentScreen: View {
    let item: PDFItem
    let library: PDFLibrary
    @State private var notebook: PDFNotebook?
    @State private var problem: String?

    var body: some View {
        Group {
            if let notebook { PDFWorkspaceView(notebook: notebook, library: library) }
            else if let problem { ContentUnavailableView("Couldn't open PDF", systemImage: "exclamationmark.triangle", description: Text(problem)) }
            else { ProgressView() }
        }
        .task {
            do { notebook = try library.open(item) }
            catch { problem = error.localizedDescription }
        }
    }
}

struct PDFWorkspaceView: View {
    let notebook: PDFNotebook
    let library: PDFLibrary
    @State private var controller = CanvasController()
    @State private var reading = true
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var results: [PDFTextReader.Match] = []
    @State private var matchIndex = 0
    @State private var searchProblem: String?
    @State private var searching = false
    @State private var searchToken = UUID()
    @State private var rebuildingSearch = false
    @State private var export: PDFExport?
    @State private var exporting = false
    @State private var renaming = false
    @State private var title = ""
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Find in PDF", text: $query).focused($searchFocused).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pdfSearch")
                if !query.isEmpty {
                    Text("\(results.isEmpty ? 0 : matchIndex + 1)/\(results.count)\(results.count == 1000 ? "+" : "")").font(.caption).monospacedDigit().accessibilityIdentifier("pdfSearchCount")
                    Button("Previous match", systemImage: "chevron.up") { moveMatch(-1) }.disabled(results.isEmpty)
                    Button("Next match", systemImage: "chevron.down") { moveMatch(1) }.disabled(results.isEmpty)
                }
            }.buttonStyle(BarIconButtonStyle()).padding(.horizontal)
            if searching || rebuildingSearch {
                HStack {
                    ProgressView(searching ? "Searching scanned text…" : "Recognizing page images…")
                    if searching { Button("Cancel Search") { query = "" } }
                }.font(.caption).padding(6).accessibilityIdentifier("pdfSearchProgress")
            }
            PDFInkView(notebook: notebook, controller: controller, reading: reading,
                       selection: results.indices.contains(matchIndex) ? results[matchIndex] : nil)
                .accessibilityIdentifier("pdfCanvas")
                .accessibilityValue("\(notebook.annotationStrokeCount) annotation strokes")
                .overlay(alignment: .bottom) {
                    if !reading { InkToolBar(controller: controller).padding(.bottom, 10) }
                }
            Text(notebook.pending ? "Saving annotations…" : "Saved locally")
                .font(.caption).foregroundStyle(.secondary).padding(4)
                .accessibilityIdentifier("pdfSaveStatus").accessibilityValue("\(notebook.annotationStrokeCount) annotation strokes")
            if let problem = notebook.problem ?? searchProblem { Text(problem).font(.footnote).foregroundStyle(.red).padding(8) }
        }
        .background { NavigationInkProtection(writing: !reading).frame(width: 0, height: 0) }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(reading ? "Write" : "Read", systemImage: reading ? "pencil.tip" : "hand.point.up") {
                    searchFocused = false; notebook.save(); reading.toggle(); controller.setReading(reading)
                }.accessibilityIdentifier("pdfReadingMode").accessibilityValue(reading ? "Reading" : "Writing")
                Menu {
                    Button("Rebuild OCR Search Index", systemImage: "text.viewfinder") { rebuildingSearch = true }
                        .disabled(rebuildingSearch).accessibilityIdentifier("rebuildPDFSearch")
                    Button("Rename PDF", systemImage: "pencil") { title = currentTitle; renaming = true }
                    Button("Export Annotated PDF", systemImage: "square.and.arrow.up") {
                        do { notebook.save(); export = PDFExport(data: try notebook.export()); exporting = true }
                        catch { notebook.problem = error.localizedDescription }
                    }.accessibilityIdentifier("exportAnnotatedPDF")
                } label: { Label("Document actions", systemImage: "ellipsis.circle") }
            }
        }
        .alert("Rename PDF", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Save") { do { try library.rename(notebook.item, title: title) } catch { notebook.problem = error.localizedDescription } }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(isPresented: $exporting, document: export, contentType: .pdf, defaultFilename: currentTitle + "-annotated") { result in
            if case .failure(let error) = result { notebook.problem = error.localizedDescription }
        }
        .task(id: rebuildingSearch) {
            guard rebuildingSearch else { return }
            defer { rebuildingSearch = false }
            do {
                try await library.refreshSearch(for: notebook.item.id, rebuild: true)
                if !query.isEmpty {
                    let requestedQuery = query, token = searchToken
                    let found = try await PDFTextReader.shared.find(requestedQuery, at: notebook.source)
                    try Task.checkCancellation()
                    if query == requestedQuery, searchToken == token { results = found; matchIndex = 0 }
                }
            } catch is CancellationError {} catch { searchProblem = error.localizedDescription }
        }
        .task(id: query) {
            let token = UUID(); searchToken = token
            searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            defer { if searchToken == token { searching = false } }
            results = []; matchIndex = 0; searchProblem = nil
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let found = try await PDFTextReader.shared.find(query, at: notebook.source)
                try Task.checkCancellation()
                results = found
            } catch is CancellationError {} catch { searchProblem = error.localizedDescription }
        }
        .onAppear { controller.setReading(true) }
        .onDisappear { library.close(notebook.item.id) }
        .onChange(of: phase) { _, phase in if phase != .active { notebook.save() } }
    }

    private var currentTitle: String { library.items.first { $0.id == notebook.item.id }?.title ?? notebook.item.title }

    private func moveMatch(_ delta: Int) {
        guard !results.isEmpty else { return }
        matchIndex = (matchIndex + delta + results.count) % results.count
    }
}

struct PDFInkView: UIViewRepresentable {
    let notebook: PDFNotebook
    let controller: CanvasController
    var reading: Bool
    var selection: PDFTextReader.Match?

    func makeCoordinator() -> Coordinator { Coordinator(notebook: notebook, controller: controller) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.pageOverlayViewProvider = context.coordinator
        view.document = notebook.document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.reading = reading
        if view.isInMarkupMode == reading { view.isInMarkupMode = !reading }
        controller.setReading(reading)
        for canvas in coordinator.canvases.values {
            canvas.isUserInteractionEnabled = !reading
            canvas.isReadOnly = reading
            canvas.drawingGestureRecognizer.isEnabled = !reading
            canvas.drawingPolicy = controller.canvasView?.drawingPolicy ?? .pencilOnly
        }
        if coordinator.selectionID != selection?.id {
            coordinator.selectionID = selection?.id
            coordinator.selection = selection
            if let selection, let page = notebook.document.page(at: selection.page), let range = selection.range, let highlight = page.selection(for: range) {
                highlight.color = .systemYellow
                view.highlightedSelections = [highlight]
                view.go(to: highlight)
            } else {
                view.highlightedSelections = nil
                if let selection, let bounds = selection.bounds, let page = notebook.document.page(at: selection.page) {
                    view.go(to: bounds.insetBy(dx: -12, dy: -20), on: page)
                }
            }
            coordinator.updateSearchHighlight(in: view)
        }
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.notebook.save()
        for canvas in coordinator.canvases.values { canvas.delegate = nil }
        view.pageOverlayViewProvider = nil
    }

    @MainActor final class Coordinator: NSObject, @MainActor PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        let notebook: PDFNotebook
        let controller: CanvasController
        var reading = true
        var selectionID: String?
        var selection: PDFTextReader.Match?
        private var searchHighlights: [CAShapeLayer] = []
        var canvases: [Int: NoteCanvasView] = [:]
        init(notebook: PDFNotebook, controller: CanvasController) {
            self.notebook = notebook; self.controller = controller
            super.init()
            controller.tools.onChange = { [weak self] in
                guard let self else { return }
                let controller = self.controller
                controller.applyTools()
                for canvas in canvases.values where canvas !== controller.canvasView {
                    canvas.tool = controller.tools.pkTool
                    canvas.drawingPolicy = controller.canvasView?.drawingPolicy ?? .pencilOnly
                }
            }
        }

        func updateSearchHighlight(in view: PDFView) {
            searchHighlights.forEach { $0.removeFromSuperlayer() }; searchHighlights.removeAll()
            guard let selection, let bounds = selection.bounds,
                  let page = notebook.document.page(at: selection.page), let canvas = canvases[selection.page], !canvas.bounds.isEmpty else { return }
            let rectangle = canvas.convert(view.convert(bounds, from: page), from: view)
            let layer = CAShapeLayer()
            layer.path = UIBezierPath(roundedRect: rectangle.insetBy(dx: -2, dy: -1), cornerRadius: 2).cgPath
            layer.fillColor = UIColor.systemYellow.withAlphaComponent(0.35).cgColor
            layer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.7).cgColor
            layer.lineWidth = 0.7; layer.zPosition = 1000
            canvas.layer.addSublayer(layer); searchHighlights.append(layer)
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let index = notebook.document.index(for: page)
            if let canvas = canvases[index] { return canvas }
            let canvas = NoteCanvasView()
            canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false; canvas.contentInsetAdjustmentBehavior = .never
            canvas.minimumZoomScale = 1; canvas.maximumZoomScale = 1
            canvas.isUserInteractionEnabled = !reading
            canvas.isReadOnly = reading
            do {
                if let saved = try notebook.pageInk(index) { canvas.savedDrawing = try PKDrawing(data: saved.drawing) }
            } catch { notebook.problem = error.localizedDescription; return nil }
            canvas.tag = index
            canvas.delegate = self
            canvases[index] = canvas
            return canvas
        }
        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? NoteCanvasView else { return }
            controller.inkIsPencilOnly = !notebook.usesTestNotebook
            #if targetEnvironment(simulator)
            controller.inkIsPencilOnly = false
            #endif
            controller.tools.load(persisting: !notebook.usesTestNotebook)
            controller.attach(canvas)
            controller.setReading(reading)
            updateSearchHighlight(in: pdfView)
        }
        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            notebook.save()
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard let canvas = canvasView as? NoteCanvasView else { return }
            controller.attach(canvas, applyingTools: false)
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let canvas = canvasView as? NoteCanvasView, !canvas.isApplyingSavedDrawing else { return }
            notebook.changed(canvas.drawing, page: canvas.tag, size: canvas.bounds.size)
            controller.refreshUndoState()
        }
    }
}
