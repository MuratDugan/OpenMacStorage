import SwiftUI

/// One actionable observation about the scanned tree ("12 GB of caches",
/// "node_modules folders"…). Computed off the main thread after each scan.
struct Insight: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case trash, caches, devArtifacts, xcode, vms, downloads, largeFiles, logs, cloud
    }

    let kind: Kind
    let bytes: Int64
    /// Item count where it adds meaning (folders found, files over 1 GB…).
    let count: Int
    /// Folder to open in Browse; nil when the insight spans many places.
    let target: FileNode?
    /// Whether the space can normally be recovered without losing user data.
    let reclaimable: Bool

    var id: String { kind.rawValue }

    /// Handled best by the Cleanup screen's safe actions rather than Browse.
    var opensCleanup: Bool { kind == .caches || kind == .devArtifacts || kind == .logs }

    var title: LocalizedStringKey {
        switch kind {
        case .trash:        "Trash"
        case .caches:       "Caches"
        case .devArtifacts: "Dependency & build folders"
        case .xcode:        "Xcode & developer data"
        case .vms:          "Virtual machines & containers"
        case .downloads:    "Downloads"
        case .largeFiles:   "Files over 1 GB"
        case .logs:         "Logs"
        case .cloud:        "Stored only in the cloud"
        }
    }

    var detail: LocalizedStringKey {
        switch kind {
        case .trash:
            "Already deleted — emptying the Trash frees this immediately."
        case .caches:
            "Apps rebuild caches on demand. Safe to clear, though apps may be slower once."
        case .devArtifacts:
            "\(count) folders like node_modules, .venv and DerivedData. Reinstall with your package manager when needed."
        case .xcode:
            "Simulators, device support files and archives. Old ones can usually go."
        case .vms:
            "Docker, OrbStack, Parallels or UTM disk images. Prune unused images inside the app."
        case .downloads:
            "Installers and one-off files tend to pile up here."
        case .largeFiles:
            "\(count) large files. Review them in Search with a size filter."
        case .logs:
            "Diagnostic logs. Rarely needed after a problem is solved."
        case .cloud:
            "Shown at full size in Finder but they take almost no space on this Mac. Not included in the totals."
        }
    }

    var symbol: String {
        switch kind {
        case .trash:        "trash.fill"
        case .caches:       "tray.full.fill"
        case .devArtifacts: "shippingbox.fill"
        case .xcode:        "hammer.fill"
        case .vms:          "macwindow.on.rectangle"
        case .downloads:    "arrow.down.circle.fill"
        case .largeFiles:   "doc.badge.ellipsis"
        case .logs:         "doc.text.magnifyingglass"
        case .cloud:        "icloud.fill"
        }
    }

    var color: Color {
        switch kind {
        case .trash:        StorageCategory.trash.color
        case .caches:       StorageCategory.caches.color
        case .devArtifacts: StorageCategory.developerXcode.color
        case .xcode:        StorageCategory.developerXcode.color
        case .vms:          StorageCategory.developerVMs.color
        case .downloads:    StorageCategory.downloads.color
        case .largeFiles:   Color.purple
        case .logs:         StorageCategory.logs.color
        case .cloud:        Theme.cloud
        }
    }
}

enum InsightEngine {
    /// Ignore findings smaller than this — they are noise on a modern disk.
    static let threshold: Int64 = 200 * 1024 * 1024

    static func analyze(root: FileNode, totals: [StorageCategory: Int64]) -> [Insight] {
        var devBytes: Int64 = 0, devCount = 0
        var largeBytes: Int64 = 0, largeCount = 0
        walk(root, devBytes: &devBytes, devCount: &devCount,
             largeBytes: &largeBytes, largeCount: &largeCount)

        let home = NSHomeDirectory()
        func node(_ relative: String) -> FileNode? { root.descendant(atPath: home + relative) }

        var out: [Insight] = []
        func add(_ kind: Insight.Kind, _ bytes: Int64, count: Int = 0,
                 target: FileNode? = nil, reclaimable: Bool) {
            guard bytes >= threshold else { return }
            out.append(Insight(kind: kind, bytes: bytes, count: count,
                               target: target, reclaimable: reclaimable))
        }

        add(.trash, totals[.trash] ?? 0, target: node("/.Trash"), reclaimable: true)
        add(.caches, totals[.caches] ?? 0, target: node("/Library/Caches"), reclaimable: true)
        add(.devArtifacts, devBytes, count: devCount, reclaimable: true)
        add(.logs, totals[.logs] ?? 0, target: node("/Library/Logs"), reclaimable: true)
        let xcode = node("/Library/Developer")
        add(.xcode, xcode?.size ?? 0, target: xcode, reclaimable: false)
        add(.vms, totals[.developerVMs] ?? 0, reclaimable: false)
        let downloads = node("/Downloads")
        add(.downloads, downloads?.size ?? 0, target: downloads, reclaimable: false)
        add(.largeFiles, largeBytes, count: largeCount, reclaimable: false)
        // Cloud is informational, never "reclaimable".
        if root.cloudSize >= threshold {
            out.append(Insight(kind: .cloud, bytes: root.cloudSize, count: 0,
                               target: node("/Library/CloudStorage"), reclaimable: false))
        }

        // Reclaimable first, then by size.
        return out.sorted {
            if $0.reclaimable != $1.reclaimable { return $0.reclaimable }
            return $0.bytes > $1.bytes
        }
    }

    private static func walk(_ node: FileNode,
                             devBytes: inout Int64, devCount: inout Int,
                             largeBytes: inout Int64, largeCount: inout Int) {
        for c in node.children {
            if c.isDirectory {
                if FastScanner.isDevArtifact(name: c.name) {
                    devBytes += c.size
                    devCount += 1
                    continue   // nested node_modules are already included
                }
                walk(c, devBytes: &devBytes, devCount: &devCount,
                     largeBytes: &largeBytes, largeCount: &largeCount)
            } else if c.size >= 1_000_000_000 {
                largeBytes += c.size
                largeCount += 1
            }
        }
    }
}
