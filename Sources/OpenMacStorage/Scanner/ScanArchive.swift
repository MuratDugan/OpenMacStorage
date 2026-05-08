import Foundation

/// Tarama sonucunun hızlı ikili formatta kaydı/okunması.
///
/// Format (little-endian, tek dosya):
///   Header (16 bayt):
///     magic        4   "SKLM"
///     version      2   UInt16  = 1
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
///     fileCount    4   Int32
///     dirCount     4   Int32
///     childCount   4   UInt32
///     children     ... aynı şema
///
/// JSON / PropertyList'a göre 10-50x daha hızlıdır; milyonlarca düğüm için
/// pratik tek seçenek.
enum ScanArchive {

    static let version: UInt16 = 1
    static let magic: [UInt8] = Array("SKLM".utf8)

    struct Metadata: Sendable {
        let rootPath: String
        let scanDate: Date
        let totalBytes: Int64
        let nodeCount: Int
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

    /// Sadece üst-bilgi (hızlı varlık kontrolü için).
    static func loadMetadata() -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return nil }
        guard Array(header.prefix(4)) == magic else { return nil }
        let v = header.readLE(UInt16.self, at: 4)
        guard v == version else { return nil }
        let bits = header.readLE(UInt64.self, at: 8)
        let date = Date(timeIntervalSince1970: Double(bitPattern: bits))

        guard let lenData = try? handle.read(upToCount: 2), lenData.count == 2 else { return nil }
        let pathLen = Int(lenData.readLE(UInt16.self, at: 0))
        guard let pathData = try? handle.read(upToCount: pathLen), pathData.count == pathLen else { return nil }
        let rootPath = String(data: pathData, encoding: .utf8) ?? "/"

        // Toplam boyutu alabilmek için root düğümünün size alanına atla:
        // nameLen(2)+name+isDir(1)+cat(1)+ownSize(8)+size(8) = okumamız lazım
        guard let nameLenData = try? handle.read(upToCount: 2), nameLenData.count == 2 else { return nil }
        let nameLen = Int(nameLenData.readLE(UInt16.self, at: 0))
        _ = try? handle.read(upToCount: nameLen + 1 + 1 + 8) // ad + isDir + cat + ownSize
        guard let sizeData = try? handle.read(upToCount: 8), sizeData.count == 8 else { return nil }
        let totalSize = sizeData.readLE(Int64.self, at: 0)
        guard let countsData = try? handle.read(upToCount: 8), countsData.count == 8 else { return nil }
        let files = Int(countsData.readLE(Int32.self, at: 0))
        let dirs = Int(countsData.readLE(Int32.self, at: 4))

        return Metadata(rootPath: rootPath, scanDate: date, totalBytes: totalSize, nodeCount: files + dirs)
    }

    /// Ağacı tam olarak yükler.
    static func load() throws -> (root: FileNode, scanDate: Date) {
        try load(from: archiveURL)
    }

    static func load(from url: URL) throws -> (root: FileNode, scanDate: Date) {
        let data = try Data(contentsOf: url)
        var cursor = 0
        guard data.count >= 16 else { throw ArchiveError.truncated }
        guard Array(data[0..<4]) == magic else { throw ArchiveError.badMagic }
        let v = data.readLE(UInt16.self, at: 4)
        guard v == version else { throw ArchiveError.unsupportedVersion(v) }
        let dateBits = data.readLE(UInt64.self, at: 8)
        let scanDate = Date(timeIntervalSince1970: Double(bitPattern: dateBits))
        cursor = 16

        let pathLen = Int(data.readLE(UInt16.self, at: cursor)); cursor += 2
        let rootPath = String(data: data[cursor..<(cursor + pathLen)], encoding: .utf8) ?? "/"
        cursor += pathLen

        let root = readNode(data: data, cursor: &cursor, parentPath: parentDir(of: rootPath))
        return (root, scanDate)
    }

    private static func parentDir(of path: String) -> String {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent()
        return url.path
    }

    private static func readNode(data: Data, cursor: inout Int, parentPath: String) -> FileNode {
        let nameLen = Int(data.readLE(UInt16.self, at: cursor)); cursor += 2
        let name = String(data: data[cursor..<(cursor + nameLen)], encoding: .utf8) ?? ""
        cursor += nameLen
        let isDir = data[cursor] != 0; cursor += 1
        let catIndex = Int(data[cursor]); cursor += 1
        let ownSize = data.readLE(Int64.self, at: cursor); cursor += 8
        let size = data.readLE(Int64.self, at: cursor); cursor += 8
        let files = Int(data.readLE(Int32.self, at: cursor)); cursor += 4
        let dirs = Int(data.readLE(Int32.self, at: cursor)); cursor += 4
        let childCount = Int(data.readLE(UInt32.self, at: cursor)); cursor += 4

        let path: String
        if name.isEmpty {
            path = parentPath
        } else if parentPath.hasSuffix("/") && name.hasPrefix("/") {
            // Root sentinel ("/") meeting parentPath="/" — avoid "//".
            path = parentPath + String(name.dropFirst())
        } else if parentPath.hasSuffix("/") {
            path = parentPath + name
        } else {
            path = parentPath + "/" + name
        }
        let category = catIndex < StorageCategory.allCases.count
            ? StorageCategory.allCases[catIndex]
            : .other

        let node = FileNode(name: name,
                            path: path,
                            isDirectory: isDir,
                            ownSize: ownSize,
                            category: category)
        node.size = size
        node.fileCount = files
        node.dirCount = dirs
        node.children.reserveCapacity(childCount)

        for _ in 0..<childCount {
            let child = readNode(data: data, cursor: &cursor, parentPath: path)
            child.parent = node
            node.children.append(child)
        }
        return node
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

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        let raw = self.withUnsafeBytes { ptr -> T in
            let base = ptr.baseAddress!.advanced(by: offset)
            var tmp: T = 0
            memcpy(&tmp, base, size)
            return tmp
        }
        return T(littleEndian: raw)
    }
}
