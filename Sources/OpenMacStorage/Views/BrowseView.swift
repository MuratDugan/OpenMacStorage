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
    let parent: FileNode
    let onOpen: (FileNode) -> Void
    let onGoUp: () -> Void

    @State private var query: String = ""
    @State private var kindFilter: FileIconInfo.KindGroup = .all
    @State private var categoryFilter: StorageCategory? = nil
    @State private var minSizeMB: Double = 0
    @State private var sort: SortKey = .sizeDesc
    @State private var selection: Set<UUID> = []
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
            tableView
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
                    .font(.callout.monospaced().weight(.medium))
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
                    Text(c.name)
                        .font(c.isDirectory ? .body.weight(.medium) : .body)
                        .lineLimit(1)
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
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(110)
            TableColumn("Share") { c in
                let frac = parent.size > 0 ? Double(c.size) / Double(parent.size) : 0
                ShareBar(fraction: frac, color: c.category.color)
            }
            .width(min: 80, ideal: 200)
            TableColumn("Kind") { c in
                Text(FileIconInfo.kindLabel(for: c))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 160)
            TableColumn("Contents") { c in
                if c.isDirectory {
                    Text("\(c.fileCount) files").font(.caption).foregroundStyle(.tertiary)
                } else { Text("") }
            }
            .width(80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
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

    private func nodes(for ids: Set<UUID>) -> [FileNode] {
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
        for n in toDelete {
            if let err = CleanupActions.moveToTrash(n.path) {
                failures.append("• \((n.path as NSString).lastPathComponent): \(err.localizedDescription)")
            } else if let idx = parent.children.firstIndex(where: { $0.id == n.id }) {
                parent.children.remove(at: idx)
            }
        }
        propagateSizeRecount(from: parent)
        selection = []
        reloadToken = UUID()
        if !failures.isEmpty {
            lastError = String(localized: "Some items couldn't be moved:") + "\n\n" +
                        failures.joined(separator: "\n")
        }
    }

    private func propagateSizeRecount(from start: FileNode) {
        var cur: FileNode? = start
        while let n = cur {
            n.size = n.children.reduce(0) { $0 + $1.size }
            n.fileCount = n.children.reduce(0) { $0 + $1.fileCount }
            n.dirCount = 1 + n.children.reduce(0) { $0 + $1.dirCount }
            cur = n.parent
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

// MARK: - Share bar

private struct ShareBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.7))
                    .frame(width: max(2, CGFloat(fraction) * geo.size.width))
            }
        }
        .frame(height: 8)
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
