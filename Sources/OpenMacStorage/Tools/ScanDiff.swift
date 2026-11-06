import Foundation

/// İki tarama (önceki + şimdiki) arasındaki klasör boyut değişimi.
struct ScanDiffEntry: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let name: String
    let isDirectory: Bool
    let oldSize: Int64
    let newSize: Int64
    var delta: Int64 { newSize - oldSize }
    enum Kind { case grew, shrank, added, removed }
    var kind: Kind {
        if oldSize == 0 && newSize > 0 { return .added }
        if newSize == 0 && oldSize > 0 { return .removed }
        return delta > 0 ? .grew : .shrank
    }
}

enum ScanDiff {

    /// İki ağacı yola göre eşleştirip büyüme/küçülme listesini üretir.
    static func compare(old: FileNode, new: FileNode, minDelta: Int64 = 100 * 1024 * 1024) -> [ScanDiffEntry] {
        var oldMap: [String: FileNode] = [:]
        flatten(old, into: &oldMap)
        var newMap: [String: FileNode] = [:]
        flatten(new, into: &newMap)

        var entries: [ScanDiffEntry] = []
        let allKeys = Set(oldMap.keys).union(newMap.keys)
        for path in allKeys {
            let o = oldMap[path]
            let n = newMap[path]
            let oldSize = o?.size ?? 0
            let newSize = n?.size ?? 0
            let delta = abs(newSize - oldSize)
            guard delta >= minDelta else { continue }
            let name = (path as NSString).lastPathComponent
            let isDir = (n ?? o)?.isDirectory ?? true
            entries.append(.init(path: path, name: name, isDirectory: isDir,
                                 oldSize: oldSize, newSize: newSize))
        }
        // En büyük mutlak değişimi tepede tut
        entries.sort { abs($0.delta) > abs($1.delta) }
        return entries
    }

    /// Sadece **klasörleri** düz haritaya çıkarır. Yapraklar gürültü yaratıyor.
    /// Path yukarıdan taşınır — düğümler artık path saklamadığından her düğümde
    /// zincirden yeniden kurmak O(n × derinlik) olurdu.
    private static func flatten(_ node: FileNode, into map: inout [String: FileNode]) {
        flattenWalk(node, path: node.path, into: &map)
    }

    private static func flattenWalk(_ node: FileNode, path: String, into map: inout [String: FileNode]) {
        guard node.isDirectory else { return }
        map[path] = node
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for c in node.children where c.isDirectory {
            flattenWalk(c, path: prefix + c.name, into: &map)
        }
    }
}
