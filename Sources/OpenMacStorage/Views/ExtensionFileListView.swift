import SwiftUI
import AppKit

/// Sheet shown when the user taps a row in `FileTypeStatsView`. Lists every
/// file with a given extension, paginated, sortable, with bulk actions.
struct ExtensionFileListView: View {
    let ext: String                     // lowercase, no leading dot
    let displayExt: String              // ".mp4" or "(no extension)"
    let tint: Color
    let icon: String
    let root: FileNode
    let onClose: () -> Void

    @State private var files: [FileNode] = []
    @State private var loading = true
    @State private var query: String = ""
    @State private var sort: SortKey = .sizeDesc
    @State private var selection: Set<UUID> = []
    @State private var page: Int = 0
    @State private var pendingDelete = false
    @State private var lastError: String?

    private let pageSize = 100

    enum SortKey: Hashable {
        case sizeDesc, sizeAsc, nameAsc, nameDesc, pathAsc
        var label: LocalizedStringKey {
            switch self {
            case .sizeDesc: "Largest first"
            case .sizeAsc:  "Smallest first"
            case .nameAsc:  "Name A → Z"
            case .nameDesc: "Name Z → A"
            case .pathAsc:  "Path"
            }
        }
    }

    private var filtered: [FileNode] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = q.isEmpty ? files : files.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        switch sort {
        case .sizeDesc: list.sort { $0.size > $1.size }
        case .sizeAsc:  list.sort { $0.size < $1.size }
        case .nameAsc:  list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .pathAsc:  list.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        }
        return list
    }

    private var pageCount: Int {
        max(1, (filtered.count + pageSize - 1) / pageSize)
    }
    private var pageEntries: [FileNode] {
        let start = page * pageSize
        let end = min(start + pageSize, filtered.count)
        guard start < end else { return [] }
        return Array(filtered[start..<end])
    }
    private var selectedSize: Int64 {
        files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            controls
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.regularMaterial)
            Divider()
            if loading {
                Spacer()
                ProgressView().controlSize(.large)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                EmptyState(icon: "tray", title: "Nothing matches",
                           message: "Loosen the search to see files.")
                Spacer()
            } else {
                listView
                Divider()
                paginationFooter
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial)
            }
        }
        .frame(minWidth: 880, idealWidth: 1000, minHeight: 580, idealHeight: 720)
        .task { await load() }
        .alert("Move to Trash", isPresented: $pendingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move", role: .destructive) { trashSelected() }
        } message: {
            Text("\(selection.count) files (\(ByteFormatter.string(selectedSize))) will be moved to the Trash.")
        }
        .alert("Error", isPresented: .init(get: { lastError != nil },
                                           set: { if !$0 { lastError = nil } })) {
            Button("OK") {}
        } message: { Text(lastError ?? "") }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: icon).foregroundStyle(tint).font(.title2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayExt).font(.title2.bold().monospaced())
                Text("\(files.count) files · \(ByteFormatter.string(files.reduce(0) { $0 + $1.size }))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter by name or path", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, _ in page = 0 }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            Picker("Sort", selection: $sort) {
                Text("Largest first").tag(SortKey.sizeDesc)
                Text("Smallest first").tag(SortKey.sizeAsc)
                Text("Name A → Z").tag(SortKey.nameAsc)
                Text("Name Z → A").tag(SortKey.nameDesc)
                Text("Path").tag(SortKey.pathAsc)
            }
            .frame(maxWidth: 200)

            Spacer()

            if !selection.isEmpty {
                Text("\(selection.count) selected · \(ByteFormatter.string(selectedSize))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    pendingDelete = true
                } label: {
                    Label("Trash (\(selection.count))", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pageEntries) { node in
                    FileEntryRow(node: node,
                                 selected: selection.contains(node.id),
                                 toggleSelect: {
                                     if selection.contains(node.id) {
                                         selection.remove(node.id)
                                     } else {
                                         selection.insert(node.id)
                                     }
                                 },
                                 onShow: { showInFinder(node.path) })
                    Divider().opacity(0.2)
                }
            }
        }
    }

    // MARK: - Pagination

    private var paginationFooter: some View {
        HStack {
            Text("Showing \(page * pageSize + 1)–\(min((page + 1) * pageSize, filtered.count)) of \(filtered.count)")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Button { page = 0 } label: { Image(systemName: "chevron.backward.2") }
                    .disabled(page == 0)
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.backward") }
                    .disabled(page == 0)
                Text("Page \(page + 1) of \(pageCount)")
                    .font(.callout.monospaced())
                    .frame(minWidth: 130)
                Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.forward") }
                    .disabled(page >= pageCount - 1)
                Button { page = pageCount - 1 } label: { Image(systemName: "chevron.forward.2") }
                    .disabled(page >= pageCount - 1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func load() async {
        let result: [FileNode] = await Task.detached {
            var out: [FileNode] = []
            collect(node: root, ext: ext, into: &out)
            return out
        }.value
        await MainActor.run {
            files = result
            loading = false
        }
    }

    private nonisolated func collect(node: FileNode, ext: String, into out: inout [FileNode]) {
        if !node.isDirectory {
            let nodeExt = (node.name as NSString).pathExtension.lowercased()
            if nodeExt == ext { out.append(node) }
        } else {
            for c in node.children { collect(node: c, ext: ext, into: &out) }
        }
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func trashSelected() {
        let toDelete = files.filter { selection.contains($0.id) }
        var failed = 0
        for n in toDelete {
            if CleanupActions.moveToTrash(n.path) != nil { failed += 1 }
        }
        // Optimistically drop all selected files from the in-memory list.
        // If some failed (permission etc), they'll re-appear after a re-scan.
        files.removeAll { selection.contains($0.id) }
        selection = []
        if failed > 0 {
            lastError = String(localized: "Some files couldn't be moved.")
        }
        // Adjust page if needed
        if page > 0 && page >= pageCount { page = max(0, pageCount - 1) }
    }
}

// MARK: - Row

private struct FileEntryRow: View {
    let node: FileNode
    let selected: Bool
    let toggleSelect: () -> Void
    let onShow: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { selected }, set: { _ in toggleSelect() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.callout)
                    .lineLimit(1)
                Text((node.path as NSString).deletingLastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormatter.string(node.size))
                .font(.body.monospaced().weight(.medium))
                .frame(width: 100, alignment: .trailing)
            Button(action: onShow) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .opacity(hovered ? 1 : 0.4)
            .help("Show in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
