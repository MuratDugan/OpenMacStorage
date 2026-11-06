import SwiftUI
import Quartz

struct BrowseView: View {
    @Environment(ScanModel.self) private var model
    @State private var path: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb(path: $path, root: model.rootNode)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.thinMaterial)
            Divider()
            if let current = path.last ?? model.rootNode {
                FolderContents(
                    parent: current,
                    onOpen: { tapped in
                        if tapped.isDirectory {
                            path.append(tapped)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: tapped.path)]
                            )
                        }
                    },
                    onGoUp: { if !path.isEmpty { path.removeLast() } }
                )
                .id(current.id)
            } else {
                ContentUnavailableView("No scan",
                                       systemImage: "folder",
                                       description: Text("Run a scan first."))
            }
        }
        .onAppear(perform: consumeBrowseTarget)
        .onChange(of: model.browseTarget?.id) { _, _ in consumeBrowseTarget() }
        .onChange(of: model.rootNode?.id) { _, _ in path = [] }
    }

    /// Opens the folder another screen asked for (files open their parent).
    private func consumeBrowseTarget() {
        guard let target = model.browseTarget, let root = model.rootNode else { return }
        model.browseTarget = nil
        let folder = target.isDirectory ? target : (target.parent ?? root)
        var chain = folder.ancestorChain + [folder]
        guard chain.first === root else { return }   // stale node from an old tree
        chain.removeFirst()
        path = chain
    }
}

// MARK: - Breadcrumb

struct Breadcrumb: View {
    @Binding var path: [FileNode]
    let root: FileNode?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let root {
                    crumb(root.name, isLast: path.isEmpty) { path = [] }
                    ForEach(Array(path.enumerated()), id: \.offset) { idx, node in
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary).font(.caption)
                        crumb(node.name, isLast: idx == path.count - 1) {
                            path = Array(path.prefix(idx + 1))
                        }
                    }
                }
            }
        }
    }
    private func crumb(_ name: String, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(.body, design: .rounded).weight(isLast ? .bold : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folder contents

struct FolderContents: View {
    @Environment(ScanModel.self) private var model
    let parent: FileNode
    let onOpen: (FileNode) -> Void
    let onGoUp: () -> Void

    @State private var query: String = ""
    @State private var kindFilter: FileIconInfo.KindGroup = .all
    @State private var categoryFilter: StorageCategory? = nil
    @State private var minSizeMB: Double = 0
    @State private var sort: SortKey = .sizeDesc
    @State private var selection: Set<FileNode.ID> = []
    @State private var reloadToken = UUID()
    @State private var pendingDelete: PendingDelete?
    @State private var lastError: String?

    enum SortKey: String, CaseIterable, Identifiable {
        case sizeDesc, sizeAsc, nameAsc, nameDesc, kindAsc
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .sizeDesc: "Size: largest"
            case .sizeAsc:  "Size: smallest"
            case .nameAsc:  "Name A → Z"
            case .nameDesc: "Name Z → A"
            case .kindAsc:  "Category"
            }
        }
    }

    struct PendingDelete: Identifiable {
        let id = UUID()
        let nodes: [FileNode]
        var totalBytes: Int64 { nodes.reduce(0) { $0 + $1.size } }
        var maxRisk: RiskAssessment.Level {
            nodes.map { RiskClassifier.assess($0.path).level }.max() ?? .none
        }
    }

    // MARK: - Filtering / sorting

    private var filtered: [FileNode] {
        _ = reloadToken
        var result = parent.children
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter { $0.name.lowercased().contains(q) }
        }
        if kindFilter != .all { result = result.filter { kindFilter.matches($0) } }
        if let c = categoryFilter { result = result.filter { $0.category == c } }
        if minSizeMB > 0 {
            let bytes = Int64(minSizeMB * 1024 * 1024)
            result = result.filter { $0.size >= bytes }
        }
        switch sort {
        case .sizeDesc: result.sort { $0.size > $1.size }
        case .sizeAsc:  result.sort { $0.size < $1.size }
        case .nameAsc:  result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .kindAsc:  result.sort { $0.category.rawValue < $1.category.rawValue }
        }
        return result
    }

    private var availableCategories: [StorageCategory] {
        Array(Set(parent.children.map(\.category))).sorted { $0.rawValue < $1.rawValue }
    }

    private var selectedNodes: [FileNode] {
        parent.children.filter { selection.contains($0.id) }
    }
    private var selectedTotalSize: Int64 {
        selectedNodes.reduce(0) { $0 + $1.size }
    }
    private var anyFilterActive: Bool {
        !query.isEmpty || kindFilter != .all || categoryFilter != nil || minSizeMB > 0
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            statsBar
            filterBar
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.regularMaterial)
            Divider()
            if parent.isSummarized {
                summarizedNotice
            } else {
                tableView
            }
            if !selection.isEmpty {
                Divider()
                selectionBar
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial)
            }
        }
        .alert("Move to Trash", isPresented: deleteBinding) {
            if let p = pendingDelete, p.maxRisk == .blocked {
                Button("OK") {}
            } else {
                Button("Cancel", role: .cancel) {}
                Button(deleteButtonLabel(), role: .destructive) { confirmDelete() }
            }
        } message: {
            if let p = pendingDelete { deleteAlertMessage(p) } else { Text("") }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") {}
        } message: { Text(lastError ?? "") }
    }

    // MARK: - Stats

    private var statsBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "scalemass").foregroundStyle(.secondary)
                Text(ByteFormatter.string(parent.size))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text("\(parent.children.count) items in this folder")
                    .font(.callout)
            }
            HStack(spacing: 6) {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
                Text("\(parent.fileCount) files total")
                    .font(.callout)
            }
            if parent.cloudSize > 0 {
                Button {
                    kindFilter = kindFilter == .cloudOnly ? .all : .cloudOnly
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.fill")
                        Text("\(ByteFormatter.string(parent.cloudSize)) only in cloud")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(kindFilter == .cloudOnly
                                               ? Theme.cloud : Theme.cloud.opacity(0.14)))
                    .foregroundStyle(kindFilter == .cloudOnly ? .white : Theme.cloud)
                }
                .buttonStyle(.plain)
                .help(Text("These files appear full-size in Finder but are not downloaded, so they use no space on this Mac. Click to filter."))
            }
            let hiddenCount = parent.children.lazy.filter(\.isHiddenFile).count
            if hiddenCount > 0 {
                Button {
                    kindFilter = kindFilter == .hidden ? .all : .hidden
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash.fill")
                            .foregroundStyle(kindFilter == .hidden ? .white : .purple)
                        Text("\(hiddenCount) hidden")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(kindFilter == .hidden
                                               ? Color.purple
                                               : Color.purple.opacity(0.14)))
                    .foregroundStyle(kindFilter == .hidden ? .white : .purple)
                }
                .buttonStyle(.plain)
                .help(Text("Items Finder hides by default. Click to filter."))
            }
            Spacer()
            if anyFilterActive {
                HStack(spacing: 6) {
                    Image(systemName: "line.horizontal.3.decrease.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Showing \(filtered.count) of \(parent.children.count)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private var summarizedNotice: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyState(icon: "shippingbox",
                       title: "Dependency folder",
                       message: "\(ByteFormatter.string(parent.size)) in \(parent.fileCount.formatted()) files. Folders like node_modules, .venv and DerivedData are measured exactly but not listed file by file — that keeps scans fast. They can be recreated by your package manager or build tool.")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: parent.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.caption)
                TextField("Filter by name", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: 240)

            Picker("", selection: $kindFilter) {
                ForEach(FileIconInfo.KindGroup.allCases) { t in
                    Label(t.label, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)

            Picker("", selection: $categoryFilter) {
                Text("All categories").tag(StorageCategory?.none)
                Divider()
                ForEach(availableCategories, id: \.self) { c in
                    Text(c.localizedName).tag(StorageCategory?.some(c))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)

            Menu {
                Button("Any size") { minSizeMB = 0 }
                Divider()
                ForEach([10, 50, 100, 500, 1024], id: \.self) { mb in
                    Button(mb >= 1024 ? "≥ 1 GB" : "≥ \(mb) MB") {
                        minSizeMB = Double(mb)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scalemass").font(.caption)
                    Text(minSizeMB == 0 ? "Any size" :
                          (minSizeMB >= 1024 ? "≥ 1 GB" : "≥ \(Int(minSizeMB)) MB"))
                        .font(.callout)
                }
            }
            .menuStyle(.button)
            .frame(maxWidth: 130)

            Spacer()

            if anyFilterActive {
                Button {
                    query = ""; kindFilter = .all
                    categoryFilter = nil; minSizeMB = 0
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }

            Picker("", selection: $sort) {
                ForEach(SortKey.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)
        }
    }

    // MARK: - Table

    private var tableView: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Name") { c in
                HStack(spacing: 10) {
                    let info = FileIconInfo.forNode(c)
                    let hidden = c.isHiddenFile
                    ZStack {
                        // Soft tinted square so the icon reads even on tight rows.
                        // Folders get a stronger tint to stand out from files.
                        RoundedRectangle(cornerRadius: 5)
                            .fill(info.color.opacity(c.isDirectory ? 0.22 : 0.14))
                            .frame(width: 22, height: 22)
                        Image(systemName: info.symbol)
                            .foregroundStyle(info.color)
                            .font(.system(size: 12, weight: c.isDirectory ? .semibold : .regular))
                    }
                    .opacity(hidden ? 0.55 : 1)
                    Text(c.name)
                        .font(c.isDirectory ? .body.weight(.medium) : .body)
                        .foregroundStyle(hidden ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: c.name))
                    if hidden {
                        Image(systemName: "eye.slash.fill")
                            .foregroundStyle(.tertiary)
                            .font(.caption2)
                            .help(Text("Hidden — Finder doesn't show this item."))
                    }
                    if c.isCloudOnly {
                        Image(systemName: "icloud")
                            .foregroundStyle(Theme.cloud)
                            .font(.caption)
                            .help(Text("Only in the cloud — \(ByteFormatter.string(c.cloudSize)) not downloaded, using no space on this Mac."))
                    }
                    if c.isSummarized {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .help(Text("Dependency folder — measured, not listed file by file."))
                    }
                    let risk = RiskClassifier.assess(c.path)
                    if risk.level >= .medium {
                        Image(systemName: risk.icon)
                            .foregroundStyle(risk.color)
                            .font(.caption)
                            .help(Text(risk.reason))
                    }
                }
            }
            TableColumn("Size") { c in
                Text(ByteFormatter.string(c.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(100)
            .width(min: 220, ideal: 380)
            TableColumn("Share") { c in
                let frac = parent.size > 0 ? Double(c.size) / Double(parent.size) : 0
                ShareBar(fraction: frac, color: c.category.color.opacity(0.8), height: 8)
            }
            .width(min: 60, ideal: 140, max: 260)
            TableColumn("Kind") { c in
                Text(FileIconInfo.kindLabel(for: c))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Contents") { c in
                HStack(spacing: 6) {
                    if c.isDirectory {
                        Text("\(c.fileCount) files").foregroundStyle(.tertiary)
                    }
                    if c.cloudSize > 0 {
                        Label(ByteFormatter.string(c.cloudSize), systemImage: "icloud")
                            .foregroundStyle(Theme.cloud)
                            .help(Text("Size in the cloud, not on this Mac"))
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
            .width(min: 80, ideal: 150)
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            menuItems(for: nodes(for: ids))
        } primaryAction: { ids in
            if let n = nodes(for: ids).first { onOpen(n) }
        }
        .onKeyPress(.space) {
            quickLook(for: selectedNodes); return .handled
        }
        .onKeyPress(.return) {
            if let n = selectedNodes.first { onOpen(n) }
            return .handled
        }
        .onKeyPress(.deleteForward) {
            if !selection.isEmpty { requestDelete(selectedNodes) }
            return .handled
        }
    }

    // MARK: - Selection bar (sticky footer when selection exists)

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selection.count) selected")
                    .font(.callout.weight(.semibold))
                Text(ByteFormatter.string(selectedTotalSize))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            let highest = highestRisk(in: selectedNodes)
            if highest >= .medium {
                let assess = RiskAssessment(level: highest, reason: "")
                HStack(spacing: 4) {
                    Image(systemName: assess.icon).foregroundStyle(assess.color)
                    Text(assess.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(assess.color)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(assess.color.opacity(0.15)))
            }
            Spacer()
            Button { showInFinder(selectedNodes) } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            Button { copyPaths(selectedNodes) } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive) {
                requestDelete(selectedNodes)
            } label: {
                Label("Move to Trash (\(selection.count))", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    @ViewBuilder
    private func menuItems(for items: [FileNode]) -> some View {
        if items.isEmpty {
            Text("Select an item")
        } else {
            Button { quickLook(for: items) } label: { Label("Preview (Space)", systemImage: "eye") }
            Button { showInFinder(items) } label: { Label("Show in Finder", systemImage: "magnifyingglass") }
            Button { copyPaths(items) } label: { Label("Copy Path", systemImage: "doc.on.clipboard") }
            Divider()
            Button(role: .destructive) {
                requestDelete(items)
            } label: {
                Label("Move to Trash (\(items.count)) — \(ByteFormatter.string(items.reduce(0) { $0 + $1.size }))",
                      systemImage: "trash")
            }
        }
    }

    private func nodes(for ids: Set<FileNode.ID>) -> [FileNode] {
        parent.children.filter { ids.contains($0.id) }
    }

    private var deleteBinding: Binding<Bool> {
        .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
    private var errorBinding: Binding<Bool> {
        .init(get: { lastError != nil }, set: { if !$0 { lastError = nil } })
    }
    private func highestRisk(in nodes: [FileNode]) -> RiskAssessment.Level {
        nodes.map { RiskClassifier.assess($0.path).level }.max() ?? .none
    }

    // MARK: - Risk-aware delete

    private func requestDelete(_ items: [FileNode]) {
        guard !items.isEmpty else { return }
        pendingDelete = PendingDelete(nodes: items)
    }

    private func deleteAlertMessage(_ p: PendingDelete) -> Text {
        switch p.maxRisk {
        case .blocked:
            let blockedNames = p.nodes
                .filter { RiskClassifier.assess($0.path).level == .blocked }
                .map { ($0.path as NSString).lastPathComponent }
                .prefix(5)
                .joined(separator: ", ")
            return Text("**Refused.** Some items are protected and cannot be deleted from here:\n\n\(blockedNames)\n\nThese are macOS system files. Touching them can break your installation.")
        case .high:
            return Text("⚠️ \(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes)))\n\nThis includes **app data** that an installed application depends on. Removing it will likely cause that app to lose settings, accounts, or refuse to launch.\n\nContinue only if you know which app this belongs to. Items will go to the Trash (recoverable).")
        case .medium:
            return Text("\(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes)))\n\nSome items are **app preferences or saved state** — apps may reset to defaults after delete. Items will be moved to the Trash.")
        case .low:
            return Text("\(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes)))\n\nThese look like cache or build artefacts — generally safe to remove. Items will go to the Trash.")
        case .none:
            return Text("\(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes))) will be moved to the Trash. You can restore them by dragging them back.")
        }
    }

    private func deleteButtonLabel() -> LocalizedStringKey {
        guard let p = pendingDelete else { return "Move" }
        switch p.maxRisk {
        case .high:    return "I understand — Move to Trash"
        case .medium:  return "Move to Trash anyway"
        default:       return "Move to Trash"
        }
    }

    private func confirmDelete() {
        guard let p = pendingDelete else { return }
        pendingDelete = nil
        let toDelete = p.nodes.filter { RiskClassifier.assess($0.path).level != .blocked }
        var failures: [String] = []
        var trashed: [FileNode] = []
        for n in toDelete {
            if let err = CleanupActions.moveToTrash(n.path) {
                failures.append("• \((n.path as NSString).lastPathComponent): \(err.localizedDescription)")
            } else {
                trashed.append(n)
            }
        }
        model.removeFromTree(trashed)
        selection = []
        reloadToken = UUID()
        if !failures.isEmpty {
            lastError = String(localized: "Some items couldn't be moved:") + "\n\n" +
                        failures.joined(separator: "\n")
        }
    }

    private func showInFinder(_ items: [FileNode]) {
        let urls = items.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(_ items: [FileNode]) {
        let paths = items.map { $0.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func quickLook(for items: [FileNode]) {
        guard !items.isEmpty else { return }
        let urls = items.map { URL(fileURLWithPath: $0.path) }
        Task { @MainActor in QuickLookPanel.shared.show(urls: urls) }
    }
}

// MARK: - Quick Look bridge

final class QuickLookPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = QuickLookPanel()
    private var urls: [URL] = []

    func show(urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
