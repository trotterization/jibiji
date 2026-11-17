import PencilKit
import SwiftUI

/// The notebook's home: every page as a preview, a way back into the page you were writing on,
/// and folders. Pages can be named, colored, pinned, filed, and dragged into a new order; the
/// layout, card size, sort, and details are the student's choice. None of this touches the ink.
struct HomeView: View {
    let notebook: NotebookModel
    let openPage: (String) -> Void
    let showCover: () -> Void

    enum Layout: String, CaseIterable { case grid, list }
    enum CardSize: String, CaseIterable {
        case small, medium, large
        var width: CGFloat { switch self { case .small: 150; case .medium: 200; case .large: 280 } }
        var name: String { rawValue.capitalized }
    }
    enum Sort: String, CaseIterable {
        case notebook, recent, name
        var name: String {
            switch self {
            case .notebook: "Notebook Order"
            case .recent: "Recently Edited"
            case .name: "Name"
            }
        }
    }
    enum Filter: Hashable { case all, pinned, unfiled, folder(String) }

    private enum Naming: Identifiable {
        case notebook, page(String), newFolder(forPage: String?), folder(String)
        var id: String {
            switch self {
            case .notebook: "notebook"
            case .page(let id): "page-\(id)"
            case .newFolder(let id): "new-\(id ?? "")"
            case .folder(let name): "folder-\(name)"
            }
        }
    }

    @AppStorage("home.layout") private var layout: Layout = .grid
    @AppStorage("home.cardSize") private var cardSize: CardSize = .medium
    @AppStorage("home.sort") private var sort: Sort = .notebook
    @AppStorage("home.details") private var showsDetails = true
    @State private var filter: Filter = .all
    @State private var naming: Naming?
    @State private var nameText = ""
    /// Bumped whenever the home page appears, so previews and dates are fresh.
    @State private var revision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let reason) = notebook.loadState {
                    ContentUnavailableView {
                        Label("Can't open the notebook", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Nothing has been changed or deleted.\n\(reason)")
                    } actions: {
                        Button("Try Again") { notebook.reload() }
                    }
                    .padding(.top, 80)
                } else {
                    header
                    continueCard
                        .padding(.top, 26)
                    filterBar
                        .padding(.top, 34)
                    pageSections
                        .padding(.top, 18)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .background(Theme.surface.ignoresSafeArea())
        .tint(.primary)
        .animation(Theme.Motion.list, value: notebook.pageIDs)
        .animation(Theme.Motion.list, value: notebook.library)
        .animation(Theme.Motion.list, value: filter)
        .animation(Theme.Motion.list, value: layout)
        .animation(Theme.Motion.list, value: cardSize)
        .animation(Theme.Motion.list, value: sort)
        .onAppear { revision += 1 }
        .onChange(of: notebook.library.folders) { _, folders in
            if case .folder(let name) = filter, !folders.contains(name) { filter = .all }
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(namingPlaceholder, text: $nameText)
                .accessibilityIdentifier("homeNameField")
            Button("Save") { commitName() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Notebook", isPresented: Binding(get: { notebook.alert != nil }, set: { if !$0 { notebook.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notebook.alert ?? "")
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: showCover) {
                Text("jibiji")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("Cover")
            .accessibilityIdentifier("showCover")

            Spacer()

            customizeMenu
            Button {
                newPage()
            } label: {
                Label("New Page", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SolidButtonStyle())
            .disabled(notebook.loadState != .ready)
            .accessibilityIdentifier("homeNewPage")
            .padding(.leading, 6)
        }
        .padding(.horizontal, 26)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Theme.surface.opacity(0.94).ignoresSafeArea(edges: .top))
    }

    private var customizeMenu: some View {
        Menu {
            Section("View") {
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(Layout.grid)
                    Label("List", systemImage: "list.bullet").tag(Layout.list)
                }
                if layout == .grid {
                    Picker("Card Size", selection: $cardSize) {
                        ForEach(CardSize.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Show Details", isOn: $showsDetails)
            }
            Section("Sort") {
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.name).tag($0) }
                }
            }
            Section {
                Button("Rename Notebook…", systemImage: "character.cursor.ibeam") { name(.notebook) }
                Button("New Folder…", systemImage: "folder.badge.plus") { name(.newFolder(forPage: nil)) }
            }
        } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(BarIconButtonStyle())
        .accessibilityIdentifier("customizeHome")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                name(.notebook)
            } label: {
                Text(notebook.notebookTitle)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .tracking(-1.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.98))
            .accessibilityHint("Renames the notebook")
            .accessibilityIdentifier("notebookTitle")
            summary
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 18)
        .rises(after: 0.02)
    }

    private var summary: Text {
        let pages = notebook.pageIDs.count
        var text = Text(pages == 1 ? "1 page" : "\(pages) pages")
        let folders = notebook.library.folders.count
        if folders > 0 { text = text + Text(folders == 1 ? "  ·  1 folder" : "  ·  \(folders) folders") }
        if let latest = notebook.pageIDs.compactMap(notebook.lastEdited).max() {
            text = text + Text("  ·  edited ") + Text(latest, format: .relative(presentation: .named))
        }
        return text
    }

    /// The page you were on, large, so getting back to writing is one tap.
    private var continueCard: some View {
        let id = notebook.currentPageID
        return Button {
            openPage(id)
        } label: {
            HStack(spacing: 22) {
                PagePreview(notebook: notebook, pageID: id, revision: revision)
                    .frame(width: 132)
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONTINUE WRITING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                    Text(notebook.title(for: id))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .tracking(-0.6)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    detail(for: id)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.onInk)
                    .frame(width: 46, height: 46)
                    .background(Color.primary, in: Circle())
            }
            .padding(18)
            .panel(radius: 22)
            .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
        .accessibilityLabel("Continue writing \(notebook.title(for: id))")
        .accessibilityIdentifier("continueWriting")
        .rises(after: 0.08)
    }

    // MARK: Folders

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", count: notebook.pageIDs.count, filter: .all, id: "filter-all")
                let pinned = notebook.pageIDs.filter { notebook.info(for: $0).pinned }.count
                if pinned > 0 {
                    chip("Pinned", systemImage: "pin.fill", count: pinned, filter: .pinned, id: "filter-pinned")
                }
                ForEach(notebook.library.folders, id: \.self) { folder in
                    chip(folder, systemImage: "folder", count: pages(in: .folder(folder)).count, filter: .folder(folder), id: "folder-\(folder)")
                        .contextMenu {
                            Button("Rename Folder…", systemImage: "pencil") { name(.folder(folder)) }
                            Button("Delete Folder", systemImage: "folder.badge.minus", role: .destructive) {
                                notebook.deleteFolder(folder)
                            }
                        }
                }
                if !notebook.library.folders.isEmpty {
                    chip("Unfiled", count: pages(in: .unfiled).count, filter: .unfiled, id: "filter-unfiled")
                }
                Button {
                    name(.newFolder(forPage: nil))
                } label: {
                    Label("Folder", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .overlay(Capsule().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("New folder")
                .accessibilityIdentifier("homeNewFolder")
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .rises(after: 0.12)
    }

    private func chip(_ title: String, systemImage: String? = nil, count: Int, filter value: Filter, id: String) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.55)
            }
            .foregroundStyle(selected ? Theme.onInk : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Theme.panel), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: Pages

    @ViewBuilder
    private var pageSections: some View {
        let shown = pages(in: filter)
        if filter == .all {
            let pinned = shown.filter { notebook.info(for: $0).pinned }
            if !pinned.isEmpty {
                sectionTitle("Pinned")
                pageCollection(pinned)
                    .padding(.bottom, 30)
                sectionTitle("All Pages")
            }
            pageCollection(pinned.isEmpty ? shown : shown.filter { !notebook.info(for: $0).pinned })
        } else if shown.isEmpty {
            Text(filter == .pinned ? "Pin a page to keep it here." : "No pages here yet. Use a page's menu to move it into this folder.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            pageCollection(shown)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
    }

    @ViewBuilder
    private func pageCollection(_ ids: [String]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize.width, maximum: cardSize.width * 1.35), spacing: 22, alignment: .top)],
                      alignment: .leading, spacing: 26) {
                ForEach(ids, id: \.self) { id in
                    pageButton(id) {
                        VStack(alignment: .leading, spacing: 9) {
                            PagePreview(notebook: notebook, pageID: id, revision: revision)
                                .overlay(alignment: .topTrailing) { badges(for: id).padding(9) }
                            HStack(spacing: 6) {
                                tagDot(for: id)
                                Text(notebook.title(for: id))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            if showsDetails {
                                detail(for: id)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        case .list:
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    pageButton(id) {
                        HStack(spacing: 16) {
                            PagePreview(notebook: notebook, pageID: id, revision: revision, radius: 6)
                                .frame(width: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    tagDot(for: id)
                                    Text(notebook.title(for: id))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                if showsDetails {
                                    detail(for: id)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            badges(for: id)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    if index < ids.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 80)
                    }
                }
            }
            .panel(radius: 18)
        }
    }

    /// A page: tap to open, hold for its menu, drag onto another page to move it there.
    private func pageButton<Label: View>(_ id: String, @ViewBuilder label: () -> Label) -> some View {
        Button { openPage(id) } label: { label() }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
            .contextMenu { pageMenu(id) }
            .draggable(id)
            .dropDestination(for: String.self) { items, _ in
                guard sort == .notebook, let moved = items.first, notebook.pageIDs.contains(moved) else { return false }
                notebook.movePage(moved, to: id)
                return true
            }
            .accessibilityLabel(notebook.title(for: id))
            .accessibilityIdentifier("homePage-\(id)")
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    @ViewBuilder
    private func pageMenu(_ id: String) -> some View {
        let info = notebook.info(for: id)
        Button("Open", systemImage: "arrow.up.right") { openPage(id) }
        Button("Rename…", systemImage: "pencil") { name(.page(id)) }
        Button(info.pinned ? "Unpin" : "Pin", systemImage: info.pinned ? "pin.slash" : "pin") { notebook.togglePin(id) }
        Menu("Color", systemImage: "circle.lefthalf.filled") {
            ForEach(PageTag.allCases) { tag in
                Button {
                    notebook.setTag(info.tag == tag ? nil : tag, for: id)
                } label: {
                    if info.tag == tag { Label(tag.name, systemImage: "checkmark") } else { Text(tag.name) }
                }
            }
            if info.tag != nil {
                Button("None") { notebook.setTag(nil, for: id) }
            }
        }
        Menu("Move to Folder", systemImage: "folder") {
            ForEach(notebook.library.folders, id: \.self) { folder in
                Button {
                    notebook.moveToFolder(id, folder: folder)
                } label: {
                    if info.folder == folder { Label(folder, systemImage: "checkmark") } else { Text(folder) }
                }
            }
            if info.folder != nil {
                Button("Remove from Folder") { notebook.moveToFolder(id, folder: nil) }
            }
            Button("New Folder…", systemImage: "folder.badge.plus") { name(.newFolder(forPage: id)) }
        }
        if sort == .notebook, let index = notebook.pageIDs.firstIndex(of: id) {
            Section {
                if index > 0 {
                    Button("Move Earlier", systemImage: "arrow.left") { notebook.movePage(id, to: notebook.pageIDs[index - 1]) }
                }
                if index < notebook.pageIDs.count - 1 {
                    Button("Move Later", systemImage: "arrow.right") { notebook.movePage(id, to: notebook.pageIDs[index + 1]) }
                }
            }
        }
    }

    @ViewBuilder
    private func badges(for id: String) -> some View {
        if notebook.info(for: id).pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(35))
                .accessibilityLabel("Pinned")
        }
    }

    @ViewBuilder
    private func tagDot(for id: String) -> some View {
        if let tag = notebook.info(for: id).tag {
            Circle().fill(tag.color).frame(width: 8, height: 8)
                .accessibilityLabel("\(tag.name) page")
        }
    }

    private func detail(for id: String) -> Text {
        var text = Text("")
        if let date = notebook.lastEdited(id) {
            text = Text("Edited ") + Text(date, format: .relative(presentation: .named))
        } else {
            text = Text("Not written yet")
        }
        if let folder = notebook.info(for: id).folder, filter != .folder(folder) {
            text = text + Text("  ·  \(folder)")
        }
        return text
    }

    // MARK: Data

    private func pages(in filter: Filter) -> [String] {
        var ids = notebook.pageIDs
        switch filter {
        case .all: break
        case .pinned: ids = ids.filter { notebook.info(for: $0).pinned }
        case .unfiled: ids = ids.filter { notebook.info(for: $0).folder == nil }
        case .folder(let name): ids = ids.filter { notebook.info(for: $0).folder == name }
        }
        switch sort {
        case .notebook:
            return ids
        case .recent:
            let dates = Dictionary(uniqueKeysWithValues: ids.map { ($0, notebook.lastEdited($0) ?? .distantPast) })
            return ids.sorted { dates[$0]! > dates[$1]! }
        case .name:
            return ids.sorted { notebook.title(for: $0).localizedStandardCompare(notebook.title(for: $1)) == .orderedAscending }
        }
    }

    private func newPage() {
        notebook.createPage()
        let id = notebook.currentPageID
        if case .folder(let folder) = filter { notebook.moveToFolder(id, folder: folder) }
        openPage(id)
    }

    // MARK: Naming

    private func name(_ target: Naming) {
        switch target {
        case .notebook: nameText = notebook.library.title ?? ""
        case .page(let id): nameText = notebook.info(for: id).name ?? ""
        case .newFolder: nameText = ""
        case .folder(let name): nameText = name
        }
        naming = target
    }

    private var namingTitle: String {
        switch naming {
        case .notebook: "Rename Notebook"
        case .page: "Rename Page"
        case .newFolder: "New Folder"
        case .folder: "Rename Folder"
        case nil: ""
        }
    }

    private var namingPlaceholder: String {
        switch naming {
        case .notebook: "Notebook"
        case .page(let id): notebook.defaultTitle(for: id)
        case .newFolder, .folder: "Folder name"
        case nil: ""
        }
    }

    private func commitName() {
        switch naming {
        case .notebook: notebook.renameNotebook(nameText)
        case .page(let id): notebook.renamePage(id, to: nameText)
        case .newFolder(let page):
            if let folder = notebook.createFolder(nameText) {
                if let page { notebook.moveToFolder(page, folder: folder) } else { filter = .folder(folder) }
            }
        case .folder(let old): notebook.renameFolder(old, to: nameText)
        case nil: break
        }
        naming = nil
    }
}

extension PageTag {
    var color: Color {
        switch self {
        case .rose: Color(red: 0.72, green: 0.36, blue: 0.32)
        case .gold: Color(red: 0.80, green: 0.58, blue: 0.20)
        case .teal: Color(red: 0.26, green: 0.48, blue: 0.45)
        case .graphite: Color(white: 0.45)
        }
    }
}

/// A page drawn small on its paper, in the current light or dark appearance.
private struct PagePreview: View {
    let notebook: NotebookModel
    let pageID: String
    let revision: Int
    var radius: CGFloat = 12

    /// A page's shape: the canvas width of an 11-inch iPad, a little taller than wide.
    static let page = CGSize(width: 820, height: 1060)

    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.panel)
            .aspectRatio(Self.page.width / Self.page.height, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.05), radius: 10, y: 4)
            .task(id: "\(pageID)-\(revision)-\(scheme == .dark)") { render() }
            .accessibilityHidden(true)
    }

    private func render() {
        let drawing = notebook.previewDrawing(for: pageID)
        guard !drawing.strokes.isEmpty else {
            withAnimation(Theme.Motion.quick) { image = nil }
            return
        }
        // The whole page, grown to take in ink written beyond it, keeping the page's shape.
        var rect = CGRect(origin: .zero, size: Self.page).union(drawing.bounds.insetBy(dx: -24, dy: -24))
        rect.origin.x = min(rect.minX, 0)
        rect.origin.y = min(rect.minY, 0)
        let aspect = Self.page.width / Self.page.height
        if rect.width / rect.height > aspect {
            rect.size.height = rect.width / aspect
        } else {
            rect.size.width = rect.height * aspect
        }
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        var rendered: UIImage?
        traits.performAsCurrent {
            rendered = drawing.image(from: rect, scale: min(1, 640 / rect.width))
        }
        withAnimation(Theme.Motion.quick) { image = rendered }
    }
}
