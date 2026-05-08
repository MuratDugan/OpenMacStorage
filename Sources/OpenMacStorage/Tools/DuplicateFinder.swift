import Foundation
import CryptoKit

/// Yinelenen dosya bulucu.
///
/// Strateji (büyük ağaçlar için en hızlı yaklaşım):
///   1. Önce **boyuta göre grupla**. Aynı boyut yoksa hash'e bile gerek yok.
///   2. Aynı boyutlu dosyalar 2'den azsa eleeg ele.
///   3. Geri kalanı için hızlı 64 KB **head-hash** (xxHash benzeri SHA1 prefix)
///      ile ön ele.
///   4. Eşleşme devam ediyorsa **tam SHA-1** ile kesin doğrulama.
///
/// Bu üç-aşamalı strateji 100k+ dosyada GB'larca okumayı önler.
struct DuplicateGroup: Identifiable, Sendable {
    let id = UUID()
    let size: Int64
    var paths: [String]
    var wastedBytes: Int64 { size * Int64(paths.count - 1) }
}

enum DuplicateFinder {

    struct Progress: Sendable {
        var phase: String
        var done: Int
        var total: Int
    }

    /// Verilen ağaçtaki dosyalar arasında yinelenenleri bulur.
    static func find(in root: FileNode,
                     minSize: Int64 = 5 * 1024 * 1024,
                     progress: @escaping @Sendable (Progress) -> Void,
                     isCancelled: @escaping @Sendable () -> Bool) async -> [DuplicateGroup] {
        // 1) Group by size
        var bySize: [Int64: [String]] = [:]
        collect(root, minSize: minSize, into: &bySize)
        progress(.init(phase: "Candidate size groups", done: 0, total: bySize.values.filter { $0.count >= 2 }.count))

        let candidates: [(size: Int64, paths: [String])] = bySize
            .filter { $0.value.count >= 2 }
            .map { (size: $0.key, paths: $0.value) }

        let totalFiles = candidates.reduce(0) { $0 + $1.paths.count }

        // 2) Head-hash ile ön ele (paralel)
        progress(.init(phase: "Head-hash (first 64 KB)", done: 0, total: totalFiles))
        var processed = 0
        var byHeadHash: [String: [String]] = [:]
        for (size, paths) in candidates {
            if isCancelled() { return [] }
            await withTaskGroup(of: (String, String?).self) { group in
                for p in paths {
                    group.addTask { (p, headHash(path: p)) }
                }
                for await (p, h) in group {
                    let key = "\(size)-\(h ?? "0")"
                    byHeadHash[key, default: []].append(p)
                }
            }
            processed += paths.count
            progress(.init(phase: "Head-hash (first 64 KB)", done: processed, total: totalFiles))
        }

        // 3) Full SHA-1 (paralel)
        let headGroups: [(key: String, paths: [String])] = byHeadHash
            .filter { $0.value.count >= 2 }
            .map { ($0.key, $0.value) }
        let totalFull = headGroups.reduce(0) { $0 + $1.paths.count }
        progress(.init(phase: "Full SHA-1", done: 0, total: totalFull))
        processed = 0
        var byFullHash: [String: [String]] = [:]
        for entry in headGroups {
            if isCancelled() { return [] }
            await withTaskGroup(of: (String, String?).self) { group in
                for p in entry.paths {
                    group.addTask { (p, fullHash(path: p)) }
                }
                for await (p, h) in group {
                    if let h {
                        let key = "\(entry.key)-\(h)"
                        byFullHash[key, default: []].append(p)
                    }
                }
            }
            processed += entry.paths.count
            progress(.init(phase: "Full SHA-1", done: processed, total: totalFull))
        }

        // 4) Sonuçlar
        var groups: [DuplicateGroup] = []
        for paths in byFullHash.values where paths.count >= 2 {
            let size = fileSize(of: paths[0])
            groups.append(DuplicateGroup(size: size, paths: paths.sorted()))
        }
        groups.sort { $0.wastedBytes > $1.wastedBytes }
        progress(.init(phase: "Completed", done: totalFull, total: totalFull))
        return groups
    }

    // MARK: - Helpers

    private static func collect(_ node: FileNode, minSize: Int64, into bucket: inout [Int64: [String]]) {
        // Skip the entire subtree of macOS-managed paths — APFS sealed-volume
        // cryptex copies, Preboot, and signed system DMGs are *intentionally*
        // duplicated by macOS itself and must never be touched.
        if isUnsafePath(node.path) { return }
        if !node.isDirectory {
            if node.size >= minSize { bucket[node.size, default: []].append(node.path) }
        } else {
            for c in node.children { collect(c, minSize: minSize, into: &bucket) }
        }
    }

    /// Paths the duplicate finder must never surface. Modifying anything here
    /// can corrupt macOS or its Signed System Volume.
    private static func isUnsafePath(_ path: String) -> Bool {
        if path.hasPrefix("/System") { return true }
        if path.hasPrefix("/private") { return true }
        if path.hasPrefix("/usr") || path.hasPrefix("/bin") ||
           path.hasPrefix("/sbin") || path.hasPrefix("/etc") { return true }
        if path.contains("/Preboot/") { return true }
        if path.contains("/Cryptexes") { return true }
        if path.contains("/Library/Apple/") { return true }
        if path.contains("/Library/CryptexLibrary") { return true }
        if path.contains(".timemachine") || path.contains("/Backups.backupdb") {
            return true
        }
        return false
    }

    private static func fileSize(of path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    /// İlk 64 KB'ın SHA-1 prefix'i.
    private static func headHash(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 64 * 1024) else { return nil }
        let digest = Insecure.SHA1.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Full SHA-1 — büyük dosyalarda streaming.
    private static func fullHash(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = Insecure.SHA1()
        while true {
            guard let chunk = try? fh.read(upToCount: 1 * 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
