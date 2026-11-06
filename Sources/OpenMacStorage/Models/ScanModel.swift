import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ScanModel {
    enum Phase: Equatable {
        case idle
        case scanning(path: String, bytes: Int64, files: Int, elapsed: Double)
        case done(elapsed: TimeInterval)
        case cancelled
        case error(String)
    }

    var phase: Phase = .idle
    var rootNode: FileNode?
    var selectedNode: FileNode?
    var systemReport: SystemDataReport?
    var volume: VolumeInfo = .boot()
    var categoryTotals: [StorageCategory: Int64] = [:]
    var lastScanDate: Date?
    /// The loaded scan came from an older version that counted cloud-only
    /// files at full size — sizes are inflated until the user rescans.
    var isLegacyScan = false

    /// Logical bytes of cloud-only files in the current tree (not on disk).
    var cloudOnlyBytes: Int64 { rootNode?.cloudSize ?? 0 }

    /// Actionable findings for Overview, refreshed after scans and deletes.
    var insights: [Insight] = []
    /// Volume that holds the scanned folder (may be an external drive).
    var scanVolume: VolumeInfo = .boot()

    /// Set by any view that wants Browse to open at a specific folder
    /// (Overview "Show in Browse", search results…). Browse consumes it.
    var browseTarget: FileNode?

    /// Flat array of every node (root excluded), rebuilt in the background
    /// after each scan or archive load. Deep search iterates this instead of
    /// recursing through the tree — contiguous memory, parallelisable, and no
    /// per-search tree-walk overhead.
    private(set) var searchIndex: [FileNode] = []
    private var indexBuildTask: Task<Void, Never>?

    private func rebuildSearchIndex(for root: FileNode) {
        indexBuildTask?.cancel()
        searchIndex = []
        indexBuildTask = Task.detached(priority: .utility) { [weak self] in
            var flat: [FileNode] = []
            flat.reserveCapacity(root.fileCount + root.dirCount)
            Self.flatten(root, into: &flat)
            if Task.isCancelled { return }
            let result = flat
            await MainActor.run { [weak self] in
                // Only publish if the tree hasn't been replaced meanwhile.
                if self?.rootNode === root { self?.searchIndex = result }
            }
        }
    }

    nonisolated private static func flatten(_ node: FileNode, into out: inout [FileNode]) {
        for child in node.children {
            out.append(child)
            if child.isDirectory { flatten(child, into: &out) }
        }
    }

    /// Detaches trashed nodes from the tree and refreshes every derived total
    /// (ancestor sizes, category totals, search index) so all views stay
    /// honest without a rescan.
    func removeFromTree(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        var parents: [ObjectIdentifier: FileNode] = [:]
        var ids = Set<FileNode.ID>()
        var removedFolder = false
        for n in nodes {
            guard let p = n.parent else { continue }
            p.children.removeAll { $0 === n }
            n.parent = nil
            parents[ObjectIdentifier(p)] = p
            ids.insert(n.id)
            if n.isDirectory && !n.children.isEmpty { removedFolder = true }
        }
        for p in parents.values { p.propagateTotalsUpward() }

        if !searchIndex.isEmpty {
            if removedFolder, let root = rootNode {
                // Descendants of a trashed folder must go too: keep only nodes
                // that still reach the root.
                searchIndex.removeAll { node in
                    var cur = node.parent
                    while let c = cur { if c === root { return false }; cur = c.parent }
                    return true
                }
            } else {
                searchIndex.removeAll { ids.contains($0.id) }
            }
        }
        if let root = rootNode {
            var totals: [StorageCategory: Int64] = [:]
            Self.aggregate(node: root, into: &totals)
            categoryTotals = totals
        }
        refreshInsights()
    }

    private var insightsTask: Task<Void, Never>?

    func refreshInsights() {
        insightsTask?.cancel()
        guard let root = rootNode else { insights = []; return }
        let totals = categoryTotals
        insightsTask = Task.detached(priority: .utility) { [weak self] in
            let found = InsightEngine.analyze(root: root, totals: totals)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                if self?.rootNode === root { self?.insights = found }
            }
        }
    }

    /// Built-in quick picks plus any external volume currently mounted under
    /// `/Volumes/`. Mounted volumes are detected dynamically so plugging in a
    /// drive and reopening the menu shows it without restarting the app.
    var rootCandidates: [String] {
        var picks: [String] = [
            NSString(string: "~").expandingTildeInPath,
            "/Applications",
            "/Library",
            "/"
        ]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            // Skip hidden / synthetic links; sort alphabetically for stable UI.
            for name in entries.sorted() where !name.hasPrefix(".") {
                let p = "/Volumes/\(name)"
                // /Volumes/Macintosh HD is the same as / on most Macs.
                if name == "Macintosh HD" { continue }
                picks.append(p)
            }
        }
        return picks
    }
    var currentRoot: String = NSString(string: "~").expandingTildeInPath

    private var cancelFlag = ManagedAtomicBool()
    private var scanTask: Task<Void, Never>?

    func startScan(root: String? = nil) {
        cancel()
        let target = root ?? currentRoot
        currentRoot = target
        cancelFlag.set(false)
        phase = .scanning(path: target, bytes: 0, files: 0, elapsed: 0)
        rootNode = nil
        selectedNode = nil
        categoryTotals = [:]
        isLegacyScan = false
        browseTarget = nil
        insights = []
        searchIndex = []
        indexBuildTask?.cancel()

        let started = Date()
        let flag = cancelFlag
        let model = self      // strong, MainActor-isolated reference

        scanTask = Task.detached(priority: .userInitiated) {
            let node = FastScanner.scan(
                root: target,
                progress: { p in
                    Task { @MainActor in
                        model.applyProgress(p)
                    }
                },
                isCancelled: { flag.get() }
            )

            var totals: [StorageCategory: Int64] = [:]
            ScanModel.aggregate(node: node, into: &totals)
            let totalsCopy = totals

            await MainActor.run {
                model.finishScan(
                    node: node,
                    totals: totalsCopy,
                    cancelled: flag.get(),
                    elapsed: Date().timeIntervalSince(started)
                )
            }
        }
    }

    fileprivate func applyProgress(_ p: FastScanner.Progress) {
        if case .scanning = phase {
            phase = .scanning(path: p.currentPath,
                              bytes: p.bytesScanned,
                              files: p.filesScanned,
                              elapsed: p.elapsedSeconds)
        }
    }

    fileprivate func finishScan(node: FileNode,
                                totals: [StorageCategory: Int64],
                                cancelled: Bool,
                                elapsed: TimeInterval) {
        if cancelled { phase = .cancelled; return }
        rootNode = node
        categoryTotals = totals
        let now = Date()
        lastScanDate = now
        phase = .done(elapsed: elapsed)
        volume = .boot()
        scanVolume = .forPath(node.path)
        currentRoot = node.path
        rebuildSearchIndex(for: node)
        refreshInsights()
        // Diske kaydet (arka planda)
        Task.detached(priority: .background) {
            do { try ScanArchive.save(root: node, scanDate: now) }
            catch { /* sessiz: tarama tamam, kayıt kritik değil */ }
        }
    }

    /// Uygulama başlangıcında çağrılır — son taramayı yükler.
    func loadLastScan() {
        guard rootNode == nil else { return }
        Task.detached(priority: .userInitiated) {
            guard let result = try? ScanArchive.load() else { return }
            var totals: [StorageCategory: Int64] = [:]
            ScanModel.aggregateTotals(node: result.root, into: &totals)
            await MainActor.run { [result, totals] in
                self.rootNode = result.root
                self.categoryTotals = totals
                self.lastScanDate = result.scanDate
                self.isLegacyScan = result.isLegacy
                self.currentRoot = result.root.path
                self.scanVolume = .forPath(result.root.path)
                self.phase = .idle
                self.rebuildSearchIndex(for: result.root)
                self.refreshInsights()
            }
        }
    }

    func cancel() {
        cancelFlag.set(true)
        scanTask?.cancel()
        scanTask = nil
    }

    func runSystemAnalysis() {
        Task { @MainActor in
            let report = await SystemDataAnalyzer.analyze()
            self.systemReport = report
        }
    }

    nonisolated static func aggregateTotals(node: FileNode, into totals: inout [StorageCategory: Int64]) {
        aggregate(node: node, into: &totals)
    }

    /// On-disk bytes per category. A classified folder's whole subtree shares
    /// its category, so the walk stops at the first classified node; summarized
    /// `.other` folders contribute their measured `ownSize`.
    nonisolated private static func aggregate(node: FileNode, into totals: inout [StorageCategory: Int64]) {
        if !node.isDirectory || node.category != .other {
            totals[node.category, default: 0] += node.size
            return
        }
        if node.ownSize > 0 { totals[.other, default: 0] += node.ownSize }
        for c in node.children { aggregate(node: c, into: &totals) }
    }
}

/// Basit atomik bool — tarayıcı thread'i okuyup yazıyor.
final class ManagedAtomicBool: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var value: Bool = false
    func get() -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return value
    }
    func set(_ v: Bool) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        value = v
    }
}
