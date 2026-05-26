import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ScanModel {
    enum Phase: Equatable {
        case idle
        case scanning(path: String, bytes: Int64, files: Int)
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
        phase = .scanning(path: target, bytes: 0, files: 0)
        rootNode = nil
        selectedNode = nil
        categoryTotals = [:]

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
            phase = .scanning(path: p.currentPath, bytes: p.bytesScanned, files: p.filesScanned)
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
        currentRoot = node.path
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
                self.currentRoot = result.root.path
                self.phase = .idle
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

    nonisolated private static func aggregate(node: FileNode, into totals: inout [StorageCategory: Int64]) {
        if !node.isDirectory {
            totals[node.category, default: 0] += node.size
        } else {
            switch node.category {
            case .applications, .developerXcode, .developerVMs, .caches, .logs,
                 .mail, .photos, .documents, .downloads, .trash, .iCloud, .systemReserved:
                totals[node.category, default: 0] += node.size
                return
            default:
                break
            }
            for c in node.children { aggregate(node: c, into: &totals) }
        }
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
