import Foundation
import Darwin

/// `getattrlistbulk(2)` + paralel worker havuzu ile çok hızlı dizin gezme.
///
/// Tasarım:
///   • Paylaşımlı bir iş kuyruğu (FIFO/LIFO bizim için fark etmez) — her giriş bir
///     "henüz taranmamış dizin" + onun `FileNode`'u.
///   • CPU sayısı kadar (max 8) worker thread; her biri kuyruktan bir dizin alır,
///     `getattrlistbulk` ile **sadece o dizinin doğrudan girişlerini** okur,
///     `FileNode`'ları üretir, alt dizinleri kuyruğa atar.
///   • Senkronizasyon kuralı: her `FileNode`'un `children` dizisine **sadece o
///     dizini sahiplenen tek worker** yazar. Hiyerarşik sahiplik sayesinde lock
///     gerekmez.
///   • Tüm worker'lar bittiğinde alt-toplam boyutlar tek thread'de yapraktan
///     yukarı doğru hesaplanır.
enum FastScanner {

    struct Progress: Sendable {
        var bytesScanned: Int64
        var filesScanned: Int
        var currentPath: String
    }

    static func scan(root: String,
                     progress: @escaping @Sendable (Progress) -> Void,
                     isCancelled: @escaping @Sendable () -> Bool) -> FileNode {
        let rootNode = FileNode(name: (root as NSString).lastPathComponent.isEmpty ? root : (root as NSString).lastPathComponent,
                                path: root,
                                isDirectory: true,
                                category: CategoryClassifier.classify(path: root, isDirectory: true))

        let queue = WorkQueue()
        queue.push([(root, rootNode)])

        let counters = Counters(progress: progress)
        let workerCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()

        // Knowing the scan root lets us tell "scanning the system" apart from
        // "user picked /Volumes/SomeDrive" — we only skip /Volumes/* in the
        // first case (otherwise external drives get an empty 0-file scan).
        let scanRoot = root
        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while !isCancelled(), let (path, node) = queue.pop() {
                    scanOneDirectory(path: path,
                                     node: node,
                                     queue: queue,
                                     scanRoot: scanRoot,
                                     counters: counters,
                                     isCancelled: isCancelled)
                    queue.finishedJob()
                }
                group.leave()
            }
        }
        group.wait()

        aggregate(rootNode)
        return rootNode
    }

    // MARK: - Single-directory scan

    private static func scanOneDirectory(path: String,
                                         node: FileNode,
                                         queue: WorkQueue,
                                         scanRoot: String,
                                         counters: Counters,
                                         isCancelled: @escaping @Sendable () -> Bool) {
        let fd = open(path, O_RDONLY | O_DIRECTORY, 0)
        if fd < 0 { return }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_ERROR)
        attrList.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        // Daha büyük buffer = daha az syscall. ~256 KB ≈ binlerce giriş/çağrı.
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        let prefix = path.hasSuffix("/") ? path : path + "/"
        var newSubdirs: [(String, FileNode)] = []
        var localBytes: Int64 = 0
        var localFiles: Int = 0

        while !isCancelled() {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }

            var ptr = buffer
            for _ in 0..<count {
                let length = ptr.load(as: UInt32.self)
                let entryStart = ptr
                var fieldPtr = ptr.advanced(by: 4)

                let returned = fieldPtr.load(as: attribute_set_t.self)
                fieldPtr = fieldPtr.advanced(by: MemoryLayout<attribute_set_t>.size)

                var name: String = ""
                var objType: fsobj_type_t = 0
                var fileSize: Int64 = 0

                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = fieldPtr.load(as: attrreference_t.self)
                    let nameBytes = fieldPtr.advanced(by: Int(ref.attr_dataoffset))
                    name = String(cString: nameBytes.assumingMemoryBound(to: CChar.self))
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<attrreference_t>.size)
                }

                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objType = fieldPtr.load(as: fsobj_type_t.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<fsobj_type_t>.size)
                }

                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt32>.size)
                }

                // ÖNEMLİ: TOTALSIZE = mantıksal boyut (sparse file'ın "görünürdeki" boyutu).
                // ALLOCSIZE = diskte gerçekten kullanılan blok sayısı.
                // OrbStack data.img.raw, iCloud "dataless" dosyaları, Time Machine
                // klonları gibi durumlarda doğru cevap ALLOCSIZE'dır.
                var totalSize: Int64 = 0
                var allocSize: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
                    totalSize = fieldPtr.load(as: Int64.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<off_t>.size)
                }
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocSize = fieldPtr.load(as: Int64.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<off_t>.size)
                }
                // Diskteki gerçek kullanım — sparse'ı doğru raporlar
                fileSize = allocSize > 0 ? allocSize : totalSize

                ptr = entryStart.advanced(by: Int(length))

                guard !name.isEmpty, name != ".", name != ".." else { continue }
                let isDir = (objType == fsobj_type_t(VDIR.rawValue))
                let childPath = prefix + name

                let category = CategoryClassifier.classify(path: childPath, isDirectory: isDir)
                let child = FileNode(name: name,
                                     path: childPath,
                                     isDirectory: isDir,
                                     ownSize: isDir ? 0 : fileSize,
                                     category: category)
                child.parent = node
                node.children.append(child)

                if isDir {
                    if !shouldSkip(path: childPath, scanRoot: scanRoot) {
                        newSubdirs.append((childPath, child))
                    }
                } else {
                    localBytes += fileSize
                    localFiles += 1
                }
            }
        }

        if !newSubdirs.isEmpty { queue.push(newSubdirs) }
        counters.add(bytes: localBytes, files: localFiles, currentPath: path)
    }

    /// Sahiplik tek-yazara ait olduğundan, tüm taramalar bittikten sonra
    /// dizin boyutları yapraktan yukarı doğru tek thread'de toplanır.
    private static func aggregate(_ node: FileNode) {
        if !node.isDirectory { return }
        var totalSize: Int64 = 0
        var files = 0
        var dirs = 0
        for c in node.children {
            aggregate(c)
            totalSize += c.size
            files += c.fileCount
            dirs += c.dirCount
        }
        node.size = totalSize
        node.fileCount = files
        node.dirCount = 1 + dirs
    }

    /// Subtrees the scanner refuses to recurse into. The /Volumes/ rule is
    /// conditional: when the user explicitly picks an external drive as the
    /// scan root (e.g. /Volumes/STRIX ARION), we keep descending; we only
    /// avoid /Volumes/* when scanning the system itself (root = "/") so
    /// external drives don't get double-counted into the main report.
    private static func shouldSkip(path: String, scanRoot: String) -> Bool {
        if path == "/System/Volumes/Data" { return true }
        if path.hasPrefix("/dev") || path.hasPrefix("/proc") || path == "/private/var/vm" { return true }
        if path.hasPrefix("/Volumes/") && !scanRoot.hasPrefix("/Volumes/") {
            return true
        }
        return false
    }
}

// MARK: - Concurrent helpers

private final class WorkQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var pending: [(String, FileNode)] = []
    private var active: Int = 0

    func push(_ items: [(String, FileNode)]) {
        cond.lock()
        pending.append(contentsOf: items)
        cond.broadcast()
        cond.unlock()
    }

    /// Bir iş döner ve `active` sayacını artırır. Hiç iş yoksa ve hiçbir worker
    /// aktif değilse `nil` döner — tarama bitmiştir.
    func pop() -> (String, FileNode)? {
        cond.lock()
        defer { cond.unlock() }
        while pending.isEmpty {
            if active == 0 { return nil }
            cond.wait()
        }
        let item = pending.removeLast()
        active += 1
        return item
    }

    func finishedJob() {
        cond.lock()
        active -= 1
        if active == 0 && pending.isEmpty {
            cond.broadcast()
        }
        cond.unlock()
    }
}

private final class Counters: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var bytes: Int64 = 0
    private var files: Int = 0
    private var lastReport: Date = .distantPast
    private let progress: @Sendable (FastScanner.Progress) -> Void

    init(progress: @escaping @Sendable (FastScanner.Progress) -> Void) {
        self.progress = progress
    }

    func add(bytes b: Int64, files f: Int, currentPath: String) {
        var snapshot: FastScanner.Progress?
        os_unfair_lock_lock(&lock)
        bytes += b
        files += f
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.05 {
            lastReport = now
            snapshot = .init(bytesScanned: bytes, filesScanned: files, currentPath: currentPath)
        }
        os_unfair_lock_unlock(&lock)
        if let snap = snapshot { progress(snap) }
    }
}
