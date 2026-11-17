import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeBackdrop: View {
    let image: UIImage?
    let adjustments: HomeBackgroundAdjustments
    let brightness: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let settings = adjustments.resolved(dark: scheme == .dark, brightness: brightness)
        GeometryReader { proxy in
            ZStack {
                Theme.surface
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [.orange.opacity(0.2), .clear, .teal.opacity(0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blur(radius: settings.blur)
                .opacity(settings.visibility)
                Color.black.opacity(settings.dimming)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HomeBackgroundEditor: View {
    let appearance: HomeAppearanceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var settings: HomeBackgroundAdjustments
    @State private var image: UIImage?
    @State private var brightness: Double
    @State private var photoChanged = false
    @State private var selection: PhotosPickerItem?
    @State private var importingFile = false
    @State private var loading = false
    @State private var importProblem: String?

    init(appearance: HomeAppearanceModel) {
        self.appearance = appearance
        _settings = State(initialValue: appearance.adjustments)
        _image = State(initialValue: appearance.image)
        _brightness = State(initialValue: appearance.brightness)
    }

    private var effective: HomeBackgroundAdjustments {
        settings.resolved(dark: scheme == .dark, brightness: brightness)
    }

    var body: some View {
        let photoActionTitle = image == nil ? "Choose Photo" : "Change Photo"
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Your notebook", systemImage: "book.closed").font(.title3.bold())
                        Text("A little space to learn.").foregroundStyle(.secondary)
                        HStack {
                            Text("Lesson notes").font(.subheadline.bold())
                            Spacer()
                            Image(systemName: "pencil.tip")
                        }
                        .padding(18).panel(radius: 12)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
                    .background { HomeBackdrop(image: image, adjustments: settings, brightness: brightness) }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("homeBackgroundPreview")
                }
                Section("Background image") {
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label(photoActionTitle, systemImage: "photo")
                    }
                    .accessibilityIdentifier("chooseHomePhoto")
                    Button("Import from Files…", systemImage: "folder") { importingFile = true }
                    if image != nil {
                        Button("Remove Photo", role: .destructive) {
                            image = nil; brightness = 0.5; photoChanged = true; selection = nil
                        }
                        .accessibilityIdentifier("removeHomePhoto")
                    }
                    if loading { ProgressView("Preparing photo…") }
                }
                Section {
                    Toggle("Automatic", isOn: Binding(get: { settings.automatic }, set: { automatic in
                        if !automatic { settings = effective }
                        settings.automatic = automatic
                    }))
                    .accessibilityIdentifier("automaticHomeBackground")
                    adjustment("Blur", keyPath: \.blur, range: 0...30, identifier: "homeBackgroundBlur", points: true)
                    adjustment("Dimming", keyPath: \.dimming, range: 0...0.8, identifier: "homeBackgroundDimming")
                    adjustment("Visibility", keyPath: \.visibility, range: 0...1, identifier: "homeBackgroundVisibility")
                } footer: {
                    Text("Automatic softens the image and adjusts it for light or dark appearance. Move any slider to make it yours.")
                }
                Section {
                    Button("Restore Defaults") {
                        settings = HomeBackgroundAdjustments()
                        image = nil; brightness = 0.5; photoChanged = true; selection = nil
                    }
                    .accessibilityIdentifier("resetHomeBackground")
                    Text("Your photo is saved locally. This changes the home screen only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let problem = importProblem ?? appearance.problem {
                    Section { Text(problem).foregroundStyle(.red).accessibilityIdentifier("homeBackgroundProblem") }
                }
            }
            .navigationTitle("Home Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let photo: HomeAppearanceModel.PhotoChange = photoChanged ? image.map { .replace($0) } ?? .remove : .unchanged
                        if appearance.save(settings, photo: photo) { dismiss() }
                    }
                    .disabled(loading)
                    .accessibilityIdentifier("saveHomeBackground")
                }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 40 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    try choose(Data(contentsOf: url, options: .mappedIfSafe))
                } catch { importProblem = "Couldn't open that image. Choose a photo under 40 MB." }
            }
            .task(id: selection) {
                guard let selection else { loading = false; return }
                loading = true
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    guard !Task.isCancelled else { return }
                    try choose(data)
                } catch {
                    guard !Task.isCancelled else { return }
                    importProblem = "Couldn't open that photo. Try another image under 40 MB."
                }
                loading = false
            }
        }
    }

    private func choose(_ data: Data) throws {
        let chosen = try HomePhoto.decode(data)
        image = chosen
        brightness = HomePhoto.brightness(chosen)
        photoChanged = true
        settings.automatic = true
        importProblem = nil
    }

    private func adjustment(_ title: String, keyPath: WritableKeyPath<HomeBackgroundAdjustments, Double>,
                            range: ClosedRange<Double>, identifier: String, points: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(points ? "\(Int(effective[keyPath: keyPath])) pt" : "\(Int(effective[keyPath: keyPath] * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { effective[keyPath: keyPath] }, set: { value in
                if settings.automatic { settings = effective }
                settings.automatic = false
                settings[keyPath: keyPath] = value
            }), in: range)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }
}

struct HomePageDetailsEditor: View {
    let notebook: NotebookModel
    let pageID: String
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var summary: String
    @State private var tag: PageTag?
    @State private var pinned: Bool
    @State private var folder: String?

    init(notebook: NotebookModel, pageID: String) {
        self.notebook = notebook
        self.pageID = pageID
        let info = notebook.info(for: pageID)
        _title = State(initialValue: info.name ?? "")
        _summary = State(initialValue: info.summary ?? "")
        _tag = State(initialValue: info.tag)
        _pinned = State(initialValue: info.pinned)
        _folder = State(initialValue: info.folder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    TextField(notebook.defaultTitle(for: pageID), text: $title)
                        .accessibilityLabel("Page title").accessibilityIdentifier("pageDetailsTitle")
                        .onChange(of: title) { _, value in title = String(value.prefix(60)) }
                    TextField("Add a description", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityLabel("Page description").accessibilityIdentifier("pageDetailsDescription")
                        .onChange(of: summary) { _, value in summary = String(value.prefix(240)) }
                }
                Section("Organize") {
                    Toggle("Pinned", isOn: $pinned).accessibilityIdentifier("pageDetailsPinned")
                    Picker("Color", selection: $tag) {
                        Text("None").tag(PageTag?.none)
                        ForEach(PageTag.allCases) { tag in Label(tag.name, systemImage: "circle.fill").foregroundStyle(tag.color).tag(Optional(tag)) }
                    }
                    Picker("Folder", selection: $folder) {
                        Text("Unfiled").tag(String?.none)
                        ForEach(notebook.library.folders, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                Section { Text("Leave the title blank to use its page number. Your handwriting stays on the page.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Page Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        notebook.editPage(pageID, name: title, summary: summary, tag: tag, pinned: pinned, folder: folder)
                        if notebook.alert == nil { dismiss() }
                    }
                    .accessibilityIdentifier("savePageDetails")
                }
            }
        }
    }
}
