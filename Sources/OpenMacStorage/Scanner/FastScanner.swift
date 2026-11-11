import Foundation
import Darwin

/// Very fast directory walker built on `getattrlistbulk(2)` and a parallel
/// worker pool.
///
/// Design:
///   • A shared work queue of "directories not yet listed" + their `FileNode`.
///   • `min(8, cores)` worker threads; each pops a directory, reads **only its
///     direct entries** with `getattrlistbulk`, creates child nodes, and pushes
///     subdirectories back onto the queue.
///   • Single-writer rule: only the worker that owns a directory appends to
///     that node's `children`, so the tree needs no locks.
///   • Directory totals are aggregated bottom-up on one thread at the end.
///
/// Accounting rules (what "size" means):
///   • Size is **allocated blocks** (`ATTR_FILE_ALLOCSIZE`), i.e. real disk
///     pressure. Sparse VM images and compressed files report what they use.
///   • **Cloud-only files** (`SF_DATALESS`: iCloud Optimize Storage,
///     Nextcloud / Google Drive / OneDrive placeholders) occupy ~0 bytes
///     locally. Their logical size is tracked separately in `cloudSize` and
///     never added to the disk total.
///   • **Hard links** are counted once (deduplicated by inode, but only for
///     files whose link count is > 1, so the lock is almost never touched).
enum FastScanner {

    struct Progress: Sendable {
        var bytesScanned: Int64
        var filesScanned: Int
        var currentPath: String
        /// Seconds since the scan started — lets the UI distinguish "slow but
        /// progressing" from "stuck", and compute a files/sec throughput.
        var elapsedSeconds: Double
    }

    /// Turns off on-demand download of cloud-only ("dataless") files and
    /// folders for this whole process. Without it, merely listing an evicted
    /// iCloud Desktop/Documents folder makes macOS fetch it from the cloud —
    /// on a nearly full disk that blocks inside the kernel indefinitely.
    /// With it, such reads fail fast instead, and nothing is ever downloaded.
    static let disableCloudMaterialization: Void = {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                           IOPOL_SCOPE_PROCESS,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }()

    static func scan(root: String,
                     progress: @escaping @Sendable (Progress) -> Void,
                     isCancelled: @escaping @Sendable () -> Bool) -> FileNode {
        _ = disableCloudMaterialization
        let rootLast = (root as NSString).lastPathComponent
        let rootNode = FileNode(rootName: rootLast.isEmpty ? root : rootLast,
                                fullPath: root,
                                category: CategoryClassifier.classify(path: root, isDirectory: true))

        let queue = WorkQueue()
        queue.push([Job(path: root, node: rootNode, summarize: false)])

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
                // One reusable 256 KB buffer per worker — allocating per
                // directory meant ~500k large malloc/free pairs per scan.
                let buffer = EntryBuffer()
                while !isCancelled(), let job = queue.pop() {
                    if job.summarize {
                        summarize(job: job, buffer: buffer, counters: counters,
                                  isCancelled: isCancelled)
                    } else {
                        scanOneDirectory(job: job, queue: queue, buffer: buffer,
                                         scanRoot: scanRoot, counters: counters,
                                         isCancelled: isCancelled)
                    }
                    queue.finishedJob()
                }
                group.leave()
            }
        }

        // Side channel: if the user clicks Stop, propagate that into the
        // queue so workers parked on `cond.wait()` exit immediately instead
        // of waiting for whatever directory is currently in-flight.
        let watcher = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watcher.schedule(deadline: .now() + 0.1, repeating: .milliseconds(150))
        watcher.setEventHandler {
            if isCancelled() { queue.cancel() }
        }
        watcher.resume()

        group.wait()
        watcher.cancel()

        aggregate(rootNode)
        return rootNode
    }

    /// Exact on-disk size of a folder (hidden files included, hard links
    /// counted once, cloud placeholders at their local size). Single-threaded
    /// and node-free — meant for measuring individual folders.
    static func measure(path: String) -> Int64 {
        _ = disableCloudMaterialization
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else {
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        let node = FileNode(rootName: (path as NSString).lastPathComponent, fullPath: path)
        summarize(job: Job(path: path, node: node, summarize: true),
                  buffer: EntryBuffer(),
                  counters: Counters(progress: { _ in }),
                  isCancelled: { false })
        return node.ownSize
    }

    // MARK: - Raw entry parsing

    /// One directory entry as returned by `getattrlistbulk`, parsed in the
    /// exact order the kernel packs attributes (see getattrlist(2) and
    /// getattrlistbulk(2)):
    ///   RETURNED_ATTRS, ERROR, NAME, OBJTYPE, FLAGS, FILEID,
    ///   then file attrs LINKCOUNT, TOTALSIZE, ALLOCSIZE.
    /// Every field is only 4-byte aligned, so all reads are unaligned loads.
    fileprivate struct RawEntry {
        var namePtr: UnsafePointer<CChar>?
        var isDirectory: Bool
        var errorCode: UInt32
        var onDiskBytes: Int64
        var cloudBytes: Int64
        var fileID: UInt64
        var linkCount: UInt32
        /// Content lives only in the cloud. For folders: not listable without
        /// a download, so the scanner doesn't descend.
        var isDataless: Bool
        /// Folder is where another volume is mounted (or an automount
        /// trigger). Never crossed, like `du -x`.
        var isMountPoint: Bool

        var name: String { namePtr.map { String(cString: $0) } ?? "" }

        /// Cheap check for "." / ".." without building a String.
        var isDotOrDotDot: Bool {
            guard let p = namePtr else { return true }
            if p[0] == 0x2E {                     // "."
                if p[1] == 0 { return true }
                if p[1] == 0x2E && p[2] == 0 { return true }
            }
            return p[0] == 0
        }
    }

    fileprivate final class EntryBuffer {
        let size = 256 * 1024
        let pointer: UnsafeMutableRawPointer
        init() { pointer = .allocate(byteCount: size, alignment: 8) }
        deinit { pointer.deallocate() }
    }

    /// SF_DATALESS from <sys/stat.h>: the file's content is not present
    /// locally (it's a cloud placeholder).
    private static let SF_DATALESS_FLAG: UInt32 = 0x4000_0000

    private static func makeAttrList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        list.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return list
    }

    /// Lists one directory, invoking `body` for every real entry. Returns
    /// false if the directory couldn't be opened.
    @discardableResult
    private static func forEachEntry(inDirectory path: String,
                                     buffer: EntryBuffer,
                                     isCancelled: () -> Bool,
                                     _ body: (RawEntry) -> Void) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        var attrList = makeAttrList()
        let cmnName = attrgroup_t(ATTR_CMN_NAME)
        let cmnType = attrgroup_t(ATTR_CMN_OBJTYPE)
        let cmnFlags = attrgroup_t(ATTR_CMN_FLAGS)
        let cmnFileID = attrgroup_t(ATTR_CMN_FILEID)
        let cmnError = attrgroup_t(ATTR_CMN_ERROR)
        let dMount = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        let mountBits = UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)
        let fLink = attrgroup_t(ATTR_FILE_LINKCOUNT)
        let fTotal = attrgroup_t(ATTR_FILE_TOTALSIZE)
        let fAlloc = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let vdir = fsobj_type_t(VDIR.rawValue)

        while !isCancelled() {
            let count = getattrlistbulk(fd, &attrList, buffer.pointer, buffer.size, 0)
            if count <= 0 { break }

            var entryPtr = UnsafeRawPointer(buffer.pointer)
            for _ in 0..<count {
                let length = Int(entryPtr.loadUnaligned(as: UInt32.self))
                var field = entryPtr + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var entry = RawEntry(namePtr: nil, isDirectory: false, errorCode: 0,
                                     onDiskBytes: 0, cloudBytes: 0, fileID: 0, linkCount: 1,
                                     isDataless: false, isMountPoint: false)

                // ERROR sits right after RETURNED_ATTRS when present.
                if returned.commonattr & cmnError != 0 {
                    entry.errorCode = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.commonattr & cmnName != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    entry.namePtr = (field + Int(ref.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self)
                    field += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & cmnType != 0 {
                    entry.isDirectory = field.loadUnaligned(as: fsobj_type_t.self) == vdir
                    field += MemoryLayout<fsobj_type_t>.size
                }
                var flags: UInt32 = 0
                if returned.commonattr & cmnFlags != 0 {
                    flags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.commonattr & cmnFileID != 0 {
                    entry.fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                entry.isDataless = flags & SF_DATALESS_FLAG != 0

                if entry.isDirectory {
                    if returned.dirattr & dMount != 0 {
                        entry.isMountPoint = field.loadUnaligned(as: UInt32.self) & mountBits != 0
                        field += 4
                    }
                } else {
                    if returned.fileattr & fLink != 0 {
                        entry.linkCount = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var total: Int64 = 0
                    var alloc: Int64 = 0
                    let hasAlloc = returned.fileattr & fAlloc != 0
                    if returned.fileattr & fTotal != 0 {
                        total = field.loadUnaligned(as: Int64.self)
                        field += 8
                    }
                    if hasAlloc {
                        alloc = field.loadUnaligned(as: Int64.self)
                        field += 8
                    }
                    // Real disk usage = allocated blocks. Only fall back to the
                    // logical size on filesystems that don't report allocation
                    // (some network shares). Cloud placeholders: blocks ≈ 0,
                    // logical size goes to the cloud bucket instead.
                    entry.onDiskBytes = hasAlloc ? alloc : total
                    if entry.isDataless {
                        entry.cloudBytes = max(0, total - alloc)
                    }
                }

                entryPtr += length
                if entry.isDotOrDotDot { continue }
                body(entry)
            }
        }
        return true
    }

    // MARK: - Single-directory scan

    private static func scanOneDirectory(job: Job,
                                         queue: WorkQueue,
                                         buffer: EntryBuffer,
                                         scanRoot: String,
                                         counters: Counters,
                                         isCancelled: () -> Bool) {
        let node = job.node
        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        // Category rules are path-prefix based, so once an ancestor is
        // classified every descendant shares it — no per-file string matching.
        let inherited: StorageCategory? = node.category == .other ? nil : node.category

        var newJobs: [Job] = []
        var localBytes: Int64 = 0
        var localFiles = 0

        forEachEntry(inDirectory: job.path, buffer: buffer, isCancelled: isCancelled) { entry in
            let name = entry.name
            guard !name.isEmpty else { return }

            // Paths are only materialised when something needs them.
            var childPath: String? = nil
            func path() -> String {
                if let childPath { return childPath }
                let p = prefix + name
                childPath = p
                return p
            }

            // Rules start at folders, so a loose file under an unclassified
            // parent is unclassified too — skip the string matching.
            let category = inherited
                ?? (entry.isDirectory
                    ? CategoryClassifier.classify(path: path(), isDirectory: true)
                    : .other)

            var onDisk = entry.onDiskBytes
            var cloud = entry.cloudBytes
            // Hard links: only files with >1 names can be duplicates, so the
            // shared inode set is touched for a tiny fraction of entries.
            if !entry.isDirectory, entry.linkCount > 1, entry.fileID != 0,
               !counters.claim(fileID: entry.fileID) {
                onDisk = 0
                cloud = 0
            }

            let child = FileNode(name: name,
                                 isDirectory: entry.isDirectory,
                                 ownSize: entry.isDirectory ? 0 : onDisk,
                                 category: category)
            child.cloudSize = entry.isDirectory ? 0 : cloud
            child.parent = node
            node.children.append(child)

            if entry.isDirectory {
                if entry.isMountPoint {
                    // Another volume (Preboot, VM, Update snapshots, disk
                    // images, network shares). Counted under "Not in this
                    // scan" instead of being mixed into this one.
                } else if entry.isDataless {
                    // Evicted to the cloud: listing it would mean downloading
                    // it. It takes ~no local space, so leave it as an empty
                    // folder.
                } else if isDevArtifact(name: name) {
                    // Measure without building millions of nodes.
                    newJobs.append(Job(path: path(), node: child, summarize: true))
                } else if !shouldSkip(path: path(), scanRoot: scanRoot) {
                    newJobs.append(Job(path: path(), node: child, summarize: false))
                }
            } else {
                localBytes += onDisk
                localFiles += 1
            }
        }

        if !newJobs.isEmpty { queue.push(newJobs) }
        counters.add(bytes: localBytes, files: localFiles, currentPath: job.path)
    }

    /// Sums a whole subtree (sizes, file count, cloud bytes) into the job's
    /// node without creating child nodes. Used for dependency folders whose
    /// contents are restorable and not worth browsing file-by-file.
    private static func summarize(job: Job,
                                  buffer: EntryBuffer,
                                  counters: Counters,
                                  isCancelled: () -> Bool) {
        var stack = [job.path]
        var bytes: Int64 = 0
        var cloud: Int64 = 0
        var files = 0
        while let dir = stack.popLast(), !isCancelled() {
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            forEachEntry(inDirectory: dir, buffer: buffer, isCancelled: isCancelled) { entry in
                if entry.isDirectory {
                    if !entry.isDataless && !entry.isMountPoint { stack.append(prefix + entry.name) }
                    return
                }
                files += 1
                if entry.linkCount > 1, entry.fileID != 0,
                   !counters.claim(fileID: entry.fileID) { return }
                bytes += entry.onDiskBytes
                cloud += entry.cloudBytes
            }
        }
        let node = job.node
        node.ownSize = bytes
        node.cloudSize = cloud
        node.fileCount = files
        counters.add(bytes: bytes, files: files, currentPath: job.path)
    }

    /// Bottom-up totals, run once on a single thread after all workers end.
    /// Summarized folders contribute their measured totals (`ownSize`, and the
    /// counts written by `summarize`).
    private static func aggregate(_ node: FileNode) {
        guard node.isDirectory else { return }
        if node.children.isEmpty {
            node.size = node.ownSize
            return
        }
        var total: Int64 = node.ownSize
        var cloud: Int64 = 0
        var files = 0
        var dirs = 0
        for c in node.children {
            aggregate(c)
            total += c.size
            cloud += c.cloudSize
            files += c.fileCount
            dirs += c.dirCount
        }
        node.size = total
        node.cloudSize = cloud
        node.fileCount = files
        node.dirCount = 1 + dirs
    }

    /// Subtrees the scanner refuses to recurse into:
    ///   1. System internals — `/dev`, swap, the synthetic `/System/Volumes/Data`
    ///      firmlink target (would double-count every user file).
    ///   2. Other volumes — when scanning `/` we skip `/Volumes/*` so external
    ///      drives don't get rolled into the system report. When the user
    ///      explicitly picks an external drive as the scan root we keep going.
    private static func shouldSkip(path: String, scanRoot: String) -> Bool {
        if path == "/System/Volumes/Data" { return true }
        if path.hasPrefix("/dev") || path.hasPrefix("/proc") || path == "/private/var/vm" { return true }
        if path.hasPrefix("/Volumes/") && !scanRoot.hasPrefix("/Volumes/") {
            return true
        }
        return false
    }

    /// Build/dependency folders whose contents are recreated from a manifest
    /// and which routinely contain hundreds of thousands of small files. They
    /// are measured exactly but not expanded into the tree.
    static let devArtifactNames: Set<String> = [
        ".venv", "venv", "node_modules",
        ".tox", "__pypackages__",
        "Pods",                   // CocoaPods
        ".gradle",                // Gradle project cache
        ".next", ".nuxt", ".turbo",
        "__pycache__", "DerivedData"
    ]

    static func isDevArtifact(name: String) -> Bool { devArtifactNames.contains(name) }

    static func isDevArtifact(_ path: String) -> Bool {
        isDevArtifact(name: (path as NSString).lastPathComponent)
    }
}

// MARK: - Concurrent helpers

private struct Job {
    let path: String
    let node: FileNode
    let summarize: Bool
}

private final class WorkQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var pending: [Job] = []
    private var active: Int = 0
    private var cancelled: Bool = false

    func push(_ items: [Job]) {
        cond.lock()
        pending.append(contentsOf: items)
        cond.broadcast()
        cond.unlock()
    }

    /// Returns the next job and bumps `active`. When nothing is pending and no
    /// worker is active, returns nil — the scan is done. Also returns nil
    /// immediately after `cancel()` so idle workers exit promptly on Stop.
    func pop() -> Job? {
        cond.lock()
        defer { cond.unlock() }
        while pending.isEmpty {
            if active == 0 || cancelled { return nil }
            cond.wait()
        }
        if cancelled { return nil }
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

    /// Wake every worker parked in `pop()` so it can exit. Workers inside a
    /// syscall finish that one directory first, but get no new work.
    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }
}

private final class Counters: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var bytes: Int64 = 0
    private var files: Int = 0
    private var lastReport: Date = .distantPast
    private let startTime: Date = Date()
    private var seenInodes: Set<UInt64> = []
    private let progress: @Sendable (FastScanner.Progress) -> Void

    init(progress: @escaping @Sendable (FastScanner.Progress) -> Void) {
        self.progress = progress
    }

    /// True the first time `fileID` is seen. Only called for files with a
    /// link count above one, so contention stays negligible.
    func claim(fileID: UInt64) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return seenInodes.insert(fileID).inserted
    }

    func add(bytes b: Int64, files f: Int, currentPath: String) {
        var snapshot: FastScanner.Progress?
        os_unfair_lock_lock(&lock)
        bytes += b
        files += f
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.05 {
            lastReport = now
            snapshot = .init(bytesScanned: bytes,
                             filesScanned: files,
                             currentPath: currentPath,
                             elapsedSeconds: now.timeIntervalSince(startTime))
        }
        os_unfair_lock_unlock(&lock)
        if let snap = snapshot { progress(snap) }
    }
}
