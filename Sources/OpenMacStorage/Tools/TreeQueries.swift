import Foundation

/// Taranmış ağaç üzerinde post-processing sorguları.
enum TreeQueries {

    // MARK: - Old / large files in Downloads

    struct OldFileEntry: Identifiable, Sendable {
        let id = UUID()
        let path: String
        let size: Int64
        let modified: Date
        let accessed: Date
    }

    /// Bir veya birden çok dizinden N günden eski dosyaları sıralı listeler.
    /// Tek başına çalışır — taranmış ağaç gerekmez.
    static func oldFiles(in roots: [String],
                         olderThanDays: Int,
                         minSize: Int64 = 50 * 1024 * 1024) async -> [OldFileEntry] {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .contentAccessDateKey]
        return await Task.detached(priority: .userInitiated) {
            var out: [OldFileEntry] = []
            for root in roots {
                let url = URL(fileURLWithPath: root)
                guard fm.fileExists(atPath: root) else { continue }
                guard let it = fm.enumerator(at: url,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { _, _ in true }) else { continue }
                while let next = it.nextObject() {
                    guard let u = next as? URL else { continue }
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    let size = Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
                    let mod = v?.contentModificationDate ?? .distantPast
                    let acc = v?.contentAccessDate ?? mod
                    guard size >= minSize else { continue }
                    // Sadece değişiklik tarihine bakıyoruz; access date macOS'ta
                    // Spotlight/iCloud sync gibi arka plan işleriyle güncellenir,
                    // güvenilmez.
                    if mod < cutoff {
                        out.append(.init(path: u.path, size: size, modified: mod, accessed: acc))
                    }
                }
            }
            return out.sorted { $0.size > $1.size }
        }.value
    }

    // MARK: - File type stats

    struct ExtStat: Identifiable, Sendable {
        let id: String
        let ext: String
        let totalBytes: Int64
        let count: Int
        var displayExt: String { ext.isEmpty ? String(localized: "(no extension)") : "." + ext }
    }

    /// Uzantıya göre toplam boyut/sayı.
    static func extensionStats(in root: FileNode, top: Int = 30) -> [ExtStat] {
        var bytes: [String: Int64] = [:]
        var counts: [String: Int] = [:]
        gather(root, bytes: &bytes, counts: &counts)
        let entries = bytes.keys.map { ext in
            ExtStat(id: ext, ext: ext, totalBytes: bytes[ext, default: 0], count: counts[ext, default: 0])
        }
        return entries.sorted { $0.totalBytes > $1.totalBytes }.prefix(top).map { $0 }
    }

    private static func gather(_ node: FileNode, bytes: inout [String: Int64], counts: inout [String: Int]) {
        if !node.isDirectory {
            let ext = (node.name as NSString).pathExtension.lowercased()
            bytes[ext, default: 0] += node.size
            counts[ext, default: 0] += 1
        } else {
            for c in node.children { gather(c, bytes: &bytes, counts: &counts) }
        }
    }
}
