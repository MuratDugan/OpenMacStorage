import Foundation

/// One node of the scanned tree. Designed to stay lean at multi-million-node
/// scale:
///
///   • **No stored path.** Every node used to carry its full path string —
///     roughly 100 heap bytes each, i.e. ~0.5 GB across a whole-disk scan.
///     The path is now derived from the parent chain on demand; only the scan
///     root keeps its absolute path.
///   • **No stored UUID.** Identity is the object itself (`ObjectIdentifier`),
///     which is free — no per-node random generation, no 16-byte field.
///   • **Cached child ordering.** `sortedChildren()` memoises its result so the
///     treemap and browser don't re-sort on every render pass.
final class FileNode: Identifiable, @unchecked Sendable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }

    let name: String
    let isDirectory: Bool
    /// Bytes this node actually occupies on disk (allocated blocks).
    /// Files: own allocation · directories: subtree total.
    var size: Int64
    /// Files: same as `size`. Directories: 0 — except "summarized" folders
    /// (dev artefacts like node_modules) whose total is measured without
    /// building child nodes; their total lives here.
    var ownSize: Int64
    var fileCount: Int
    var dirCount: Int
    /// Logical bytes that exist only in the cloud (iCloud "Optimize Storage",
    /// Nextcloud / Google Drive / OneDrive File Provider placeholders). These
    /// take **no** local space, so they are tracked separately from `size`.
    var cloudSize: Int64 = 0
    var children: [FileNode]
    weak var parent: FileNode?
    var category: StorageCategory

    /// Absolute path stored only on the scan root; nil everywhere else.
    private let rootPath: String?

    private var sortCache: [FileNode]?
    private var sortCacheCount: Int = -1

    /// Child node — path derives from the parent chain once `parent` is set.
    init(name: String,
         isDirectory: Bool,
         ownSize: Int64 = 0,
         category: StorageCategory = .other) {
        self.name = name
        self.rootPath = nil
        self.isDirectory = isDirectory
        self.ownSize = ownSize
        self.size = ownSize
        self.fileCount = isDirectory ? 0 : 1
        self.dirCount = isDirectory ? 1 : 0
        self.children = []
        self.category = category
    }

    /// Scan root — the only node that stores its absolute path.
    init(rootName: String,
         fullPath: String,
         category: StorageCategory = .other) {
        self.name = rootName
        self.rootPath = fullPath
        self.isDirectory = true
        self.ownSize = 0
        self.size = 0
        self.fileCount = 0
        self.dirCount = 1
        self.children = []
        self.category = category
    }

    /// Absolute path, rebuilt by walking up to the root. O(depth) — fine for
    /// UI use (visible rows, tooltips, context menus). Hot paths that touch
    /// millions of nodes should carry a prefix down the tree instead.
    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    var displaySize: String { ByteFormatter.string(size) }

    /// True for dot-files — things Finder hides by default.
    var isHiddenFile: Bool { name.hasPrefix(".") }

    /// A file whose content lives only in the cloud — it shows up in Finder
    /// with its full size but uses (almost) no local blocks.
    var isCloudOnly: Bool { !isDirectory && cloudSize > 0 && size < 64 * 1024 }

    /// A folder measured in one pass without materialising its children
    /// (node_modules, .venv…). Size is exact; contents aren't browsable.
    var isSummarized: Bool { isDirectory && children.isEmpty && fileCount > 0 }

    /// Re-derives totals from children (after a delete). Summarized folders
    /// keep their measured totals.
    func recomputeFromChildren() {
        guard isDirectory else { return }
        if children.isEmpty {
            // A normal folder whose last child was just trashed becomes empty;
            // a summarized folder (ownSize > 0) keeps its measured totals.
            if ownSize == 0 { size = 0; cloudSize = 0; fileCount = 0; dirCount = 1 }
            invalidateSortCache()
            return
        }
        var s: Int64 = 0, c: Int64 = 0, f = 0, d = 0
        for child in children {
            s += child.size; c += child.cloudSize
            f += child.fileCount; d += child.dirCount
        }
        size = s; cloudSize = c; fileCount = f; dirCount = 1 + d
        invalidateSortCache()
    }

    /// Recomputes this node and every ancestor up to the root.
    func propagateTotalsUpward() {
        var cur: FileNode? = self
        while let n = cur {
            n.recomputeFromChildren()
            cur = n.parent
        }
    }

    /// Finds a descendant by absolute path by walking names from this node.
    /// O(depth × siblings) — meant for a handful of lookups, not hot paths.
    func descendant(atPath target: String) -> FileNode? {
        let base = path
        guard target.hasPrefix(base) else { return nil }
        var rest = target.dropFirst(base.count)
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        if rest.isEmpty { return self }
        var node: FileNode = self
        for part in rest.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// Ancestors from the root down to (and excluding) this node.
    var ancestorChain: [FileNode] {
        var chain: [FileNode] = []
        var cur = parent
        while let p = cur { chain.append(p); cur = p.parent }
        return chain.reversed()
    }

    /// Children sorted by size, largest first. Memoised; the cache invalidates
    /// automatically when the child count changes (e.g. after a delete) or
    /// explicitly via `invalidateSortCache()` when sizes shift.
    func sortedChildren() -> [FileNode] {
        if let cached = sortCache, sortCacheCount == children.count { return cached }
        let sorted = children.sorted { $0.size > $1.size }
        sortCache = sorted
        sortCacheCount = children.count
        return sorted
    }

    func invalidateSortCache() {
        sortCache = nil
        sortCacheCount = -1
    }
}
