import SwiftUI

extension StorageCategory: Identifiable {
    var id: String { rawValue }
}

/// Where a category's bytes actually live. A category total is usually spread
/// over many folders (e.g. Developer = Homebrew + ~/.npm + thousands of
/// node_modules), so this splits it into rows whose sizes add up to the total.
enum CategoryBreakdown {
    struct Row: Identifiable, Sendable {
        enum Kind: Sendable {
            /// The whole folder/file belongs to the category.
            case whole
            /// An unclassified folder holding this many category places.
            case partial
            /// Unclassified files sitting directly in this folder ("Other").
            case looseFiles
        }
        let node: FileNode
        let bytes: Int64
        let places: Int
        let kind: Kind
        var id: String { "\(ObjectIdentifier(node).hashValue)-\(kind)" }
    }

    /// Splits `category` into at most ~`maxRows` rows. Big unclassified
    /// folders are opened up level by level; small ones stay grouped.
    static func compute(_ category: StorageCategory, root: FileNode, maxRows: Int = 40) -> [Row] {
        if root.category == category && category != .other {
            return [Row(node: root, bytes: root.size, places: 1, kind: .whole)]
        }
        guard root.category == .other else { return [] }

        // Bytes + place count of `category` under each unclassified folder.
        var memo: [ObjectIdentifier: (Int64, Int)] = [:]
        func tally(_ dir: FileNode) -> (Int64, Int) {
            if let m = memo[ObjectIdentifier(dir)] { return m }
            var bytes: Int64 = 0, places = 0
            if category == .other && dir.ownSize > 0 { bytes += dir.ownSize; places += 1 }
            for c in dir.children {
                if c.isDirectory && c.category == .other {
                    let t = tally(c)
                    bytes += t.0; places += t.1
                } else if c.category == category {
                    bytes += c.size; places += 1
                }
            }
            memo[ObjectIdentifier(dir)] = (bytes, places)
            return (bytes, places)
        }

        func rows(inside dir: FileNode) -> [Row] {
            var out: [Row] = []
            var loose: Int64 = category == .other ? dir.ownSize : 0
            var looseCount = 0
            for c in dir.children {
                if c.isDirectory && c.category == .other {
                    let t = tally(c)
                    guard t.0 > 0 else { continue }
                    out.append(Row(node: c, bytes: t.0, places: t.1,
                                   kind: c.isSummarized ? .whole : .partial))
                } else if c.category == category {
                    if category == .other {
                        loose += c.size; looseCount += 1
                    } else if c.size > 0 {
                        out.append(Row(node: c, bytes: c.size, places: 1, kind: .whole))
                    }
                }
            }
            if loose > 0 {
                out.append(Row(node: dir, bytes: loose, places: max(1, looseCount), kind: .looseFiles))
            }
            return out
        }

        let total = tally(root).0
        let threshold = max(total / Int64(maxRows), 50 * 1024 * 1024)
        var result = rows(inside: root)
        // A group holding a single place says nothing — show the place itself
        // (/opt → /opt/homebrew). Doesn't count against the row budget.
        func collapseSingles() {
            while let i = result.firstIndex(where: { $0.kind == .partial && $0.places == 1 }) {
                let opened = rows(inside: result[i].node)
                result.remove(at: i)
                result.append(contentsOf: opened)
            }
        }
        collapseSingles()
        while result.count < maxRows {
            // Open up the biggest still-grouped folder.
            guard let i = result.indices
                .filter({ result[$0].kind == .partial && result[$0].bytes >= threshold })
                .max(by: { result[$0].bytes < result[$1].bytes }) else { break }
            let opened = rows(inside: result[i].node)
            result.remove(at: i)
            result.append(contentsOf: opened)
            collapseSingles()
        }
        return result.sorted { $0.bytes > $1.bytes }
    }
}

struct CategoryBreakdownView: View {
    let category: StorageCategory
    let root: FileNode
    let total: Int64
    @Environment(ScanModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [CategoryBreakdown.Row]?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(Theme.Space.l)
            Divider()
            if let rows {
                if rows.isEmpty {
                    EmptyState(icon: category.symbol, title: "Nothing here",
                               message: "This category is empty in the current scan.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { row in
                                BreakdownRow(row: row, total: max(1, total), color: category.color,
                                             rootPath: root.path) {
                                    model.browseTarget = row.node
                                    dismiss()
                                }
                            }
                        }
                        .padding(Theme.Space.s)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 620)
        .task {
            let c = category, r = root
            rows = await Task.detached(priority: .userInitiated) {
                CategoryBreakdown.compute(c, root: r)
            }.value
        }
    }

    private var header: some View {
        let places = rows?.reduce(0) { $0 + $1.places } ?? 0
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: category.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(category.color)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(category.color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.localizedName).font(.title2.weight(.semibold))
                Group {
                    if category == .other {
                        Text("Files that match no category, by folder")
                    } else if places > 1 {
                        Text("Spread over \(places.formatted()) places")
                    } else {
                        Text("Where this space is")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormatter.string(total))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.leading, Theme.Space.s)
        }
    }
}

private struct BreakdownRow: View {
    let row: CategoryBreakdown.Row
    let total: Int64
    let color: Color
    let rootPath: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(row.kind == .partial ? Color.secondary : color)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill((row.kind == .partial ? Color.secondary : color).opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(Text(verbatim: row.node.path))
                        Spacer(minLength: Theme.Space.s)
                        Text(ByteFormatter.string(row.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Theme.Space.xs) {
                        ShareBar(fraction: Double(row.bytes) / Double(total), color: color, height: 4)
                        caption
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.quick) { hovering = h } }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.node.path)])
            }
        }
    }

    private var icon: String {
        switch row.kind {
        case .looseFiles: "doc.on.doc"
        case .partial:    "folder"
        case .whole:      row.node.isSummarized ? "shippingbox.fill"
                          : (row.node.isDirectory ? "folder.fill" : "doc.fill")
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch row.kind {
        case .partial:    Text("\(row.places.formatted()) places inside")
        case .looseFiles: Text("\(row.places.formatted()) files directly here")
        case .whole:      row.node.isSummarized ? Text("Dependency folder") : Text(verbatim: "")
        }
    }

    private var displayPath: String {
        (row.node.path as NSString).abbreviatingWithTildeInPath
    }
}
