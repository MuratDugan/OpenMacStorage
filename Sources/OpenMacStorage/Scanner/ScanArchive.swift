import Foundation

/// Tarama sonucunun hızlı ikili formatta kaydı/okunması.
///
/// Format (little-endian, tek dosya):
///   Header (16 bayt):
///     magic        4   "SKLM"
///     version      2   UInt16  = 2 (1 is still readable)
///     flags        2   UInt16  (rezerve)
///     scanDate     8   Float64 (UNIX epoch saniyesi)
///   Sonra: rootPath UTF-8 string (UInt16 length + bytes)
///   Sonra: pre-order düğüm akışı (recursive):
///     nameLen      2   UInt16
///     nameBytes    n
///     isDir        1   UInt8
///     category     1   UInt8 (enum index)
///     ownSize      8   Int64
///     size         8   Int64
///     cloudSize    8   Int64   (v2+: logical bytes only in the cloud)
///     fileCount    4   Int32
///     dirCount     4   Int32
///     childCount   4   UInt32
///     children     ... aynı şema
///
/// JSON / PropertyList'a göre 10-50x daha hızlıdır; milyonlarca düğüm için
/// pratik tek seçenek.
enum ScanArchive {

    static let version: UInt16 = 2
    static let magic: [UInt8] = Array("SKLM".utf8)

    struct Loaded {
        let root: FileNode
        let scanDate: Date
        /// v1 archives were written by the old scanner, which counted
        /// cloud-only files at full size. The UI suggests a rescan.
        let isLegacy: Bool
    }

    // MARK: - File location

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OpenMacStorage", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Migrate scans from the previous folder name (pre-rename) once.
        let legacy = base.appendingPathComponent("SaklamaAlani", isDirectory: true)
        if fm.fileExists(atPath: legacy.path) {
            for entry in (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? [] {
                let src = legacy.appendingPathComponent(entry)
                let dst = dir.appendingPathComponent(entry)
                if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: src, to: dst) }
            }
            try? fm.removeItem(at: legacy)
        }
        return dir
    }

    static var archiveURL: URL { directoryURL.appendingPathComponent("scan.bin") }
    static var previousURL: URL { directoryURL.appendingPathComponent("scan-previous.bin") }

    // MARK: - Save

    static func save(root: FileNode, scanDate: Date = Date()) throws {
        // Mevcut taramayı "önceki" olarak yedekle (karşılaştırma için)
        let fm = FileManager.default
        if fm.fileExists(atPath: archiveURL.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: archiveURL, to: previousURL)
        }

        var data = Data()
        data.reserveCapacity(estimatedSize(of: root))

        // Header
        data.append(contentsOf: magic)
        data.appendLE(UInt16(version))
        data.appendLE(UInt16(0))   // flags
        data.appendLE(scanDate.timeIntervalSince1970.bitPattern)

        // Root path
        let rootPathBytes = Array(root.path.utf8)
        data.appendLE(UInt16(rootPathBytes.count))
        data.append(contentsOf: rootPathBytes)

        // Tree
        writeNode(root, into: &data)

        try data.write(to: archiveURL, options: .atomic)
    }

    private static func writeNode(_ node: FileNode, into data: inout Data) {
        let nameBytes = Array(node.name.utf8)
        data.appendLE(UInt16(nameBytes.count))
        data.append(contentsOf: nameBytes)
        data.append(node.isDirectory ? 1 : 0)
        data.append(UInt8(StorageCategory.allCases.firstIndex(of: node.category) ?? 0))
        data.appendLE(node.ownSize)
        data.appendLE(node.size)
        data.appendLE(node.cloudSize)
        data.appendLE(Int32(min(node.fileCount, Int(Int32.max))))
        data.appendLE(Int32(min(node.dirCount, Int(Int32.max))))
        data.appendLE(UInt32(node.children.count))
        for c in node.children { writeNode(c, into: &data) }
    }

    private static func estimatedSize(of node: FileNode) -> Int {
        // Heuristik: ortalama 64 bayt/düğüm (path olmadan)
        return max(1024, (node.fileCount + node.dirCount) * 64)
    }

    // MARK: - Load

    /// Ağacı tam olarak yükler.
    static func load() throws -> Loaded {
        try load(from: archiveURL)
    }

    /// Single-pass loader over raw bytes with an explicit stack. Compared to
    /// the old per-field `Data` reads (a bounds-checked closure per integer,
    /// ~36 M closure calls for a 4 M-node tree) this parses the whole file in
    /// one `withUnsafeBytes` and builds strings straight from the buffer.
    static func load(from url: URL) throws -> Loaded {
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else { throw ArchiveError.truncated }

        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var cursor = 0
            let total = raw.count

            @inline(__always) func need(_ n: Int) throws {
                if cursor + n > total { throw ArchiveError.truncated }
            }
            @inline(__always) func readU16() throws -> UInt16 {
                try need(2)
                defer { cursor += 2 }
                return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt16.self))
            }
            @inline(__always) func readU32() throws -> UInt32 {
                try need(4)
                defer { cursor += 4 }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
            }
            @inline(__always) func readI32() throws -> Int32 {
                try need(4)
                defer { cursor += 4 }
                return Int32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
            }
            @inline(__always) func readI64() throws -> Int64 {
                try need(8)
                defer { cursor += 8 }
                return Int64(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self))
            }
            @inline(__always) func readU64() throws -> UInt64 {
                try need(8)
                defer { cursor += 8 }
                return UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self))
            }
            @inline(__always) func readString(_ len: Int) throws -> String {
                try need(len)
                defer { cursor += len }
                return String(decoding: UnsafeRawBufferPointer(rebasing: raw[cursor..<cursor + len]),
                              as: UTF8.self)
            }

            // Header
            guard raw[0] == magic[0], raw[1] == magic[1],
                  raw[2] == magic[2], raw[3] == magic[3] else { throw ArchiveError.badMagic }
            cursor = 4
            let v = try readU16()
            guard v == 1 || v == version else { throw ArchiveError.unsupportedVersion(v) }
            let hasCloud = v >= 2
            _ = try readU16() // flags
            let scanDate = Date(timeIntervalSince1970: Double(bitPattern: try readU64()))
            let rootPath = try readString(Int(try readU16()))

            let categories = StorageCategory.allCases

            // One node frame; returns (node, childCount).
            @inline(__always) func readFrame(asRoot: Bool) throws -> (FileNode, Int) {
                let name = try readString(Int(try readU16()))
                try need(2)
                let isDir = raw[cursor] != 0
                let catIndex = Int(raw[cursor + 1])
                cursor += 2
                let ownSize = try readI64()
                let size = try readI64()
                let cloud = hasCloud ? try readI64() : 0
                let files = Int(try readI32())
                let dirs = Int(try readI32())
                let childCount = Int(try readU32())

                let category = catIndex < categories.count ? categories[catIndex] : .other
                let node: FileNode
                if asRoot {
                    node = FileNode(rootName: name, fullPath: rootPath, category: category)
                } else {
                    node = FileNode(name: name, isDirectory: isDir,
                                    ownSize: ownSize, category: category)
                }
                node.size = size
                node.ownSize = ownSize
                node.cloudSize = cloud
                node.fileCount = files
                node.dirCount = dirs
                if childCount > 0 { node.children.reserveCapacity(childCount) }
                return (node, childCount)
            }

            let (root, rootChildren) = try readFrame(asRoot: true)

            // Depth-first reconstruction with an explicit stack — no recursion,
            // no per-node closure overhead.
            var stack: [(node: FileNode, remaining: Int)] = []
            stack.reserveCapacity(64)
            if rootChildren > 0 { stack.append((root, rootChildren)) }

            while var top = stack.popLast() {
                guard top.remaining > 0 else { continue }
                top.remaining -= 1
                stack.append(top)

                let (child, grandchildren) = try readFrame(asRoot: false)
                child.parent = top.node
                top.node.children.append(child)
                if grandchildren > 0 { stack.append((child, grandchildren)) }
            }

            return Loaded(root: root, scanDate: scanDate, isLegacy: !hasCloud)
        }
    }

    enum ArchiveError: Error {
        case truncated
        case badMagic
        case unsupportedVersion(UInt16)
    }
}

// MARK: - Data little-endian helpers

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { buf in
            self.append(buf.bindMemory(to: UInt8.self).baseAddress!, count: MemoryLayout<T>.size)
        }
    }
}
