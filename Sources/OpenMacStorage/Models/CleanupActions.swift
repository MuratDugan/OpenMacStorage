import Foundation

/// Safe cleanup operations. Each one runs with user confirmation,
/// measures in the background, and returns how much space was freed.
enum CleanupActions {
    struct Result: Sendable {
        let title: LocalizedStringResource
        let bytesFreed: Int64
        let success: Bool
        let message: LocalizedStringResource
    }

    /// Empties the contents of a directory (not the directory itself).
    static func emptyDirectory(at path: String, title: LocalizedStringResource) async -> Result {
        let before = SystemDataAnalyzer.directorySize(at: path)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            return .init(title: title, bytesFreed: 0, success: false,
                         message: "Couldn't access: \(path)")
        }
        var failed = 0
        for entry in entries {
            let p = (path as NSString).appendingPathComponent(entry)
            do { try fm.removeItem(atPath: p) } catch { failed += 1 }
        }
        let after = SystemDataAnalyzer.directorySize(at: path)
        let freed = max(0, before - after)
        return .init(title: title,
                     bytesFreed: freed,
                     success: failed == 0,
                     message: failed == 0 ? "Done" : "\(failed) items couldn't be deleted (permission)")
    }

    /// APFS local snapshots.
    static func deleteLocalSnapshots() async -> Result {
        APFSSnapshots.deleteAll()
        return .init(title: "APFS Local Snapshots",
                     bytesFreed: 0,
                     success: true,
                     message: "tmutil deletelocalsnapshots / executed")
    }

    /// Deletes unavailable iOS simulators.
    static func deleteUnavailableSimulators() async -> Result {
        let proc = Process()
        proc.launchPath = "/usr/bin/xcrun"
        proc.arguments = ["simctl", "delete", "unavailable"]
        do { try proc.run(); proc.waitUntilExit() } catch {
            return .init(title: "Old Simulators", bytesFreed: 0, success: false,
                         message: "\(error.localizedDescription)")
        }
        return .init(title: "Old Simulators", bytesFreed: 0, success: true, message: "Done")
    }

    /// Empties the Trash (via Finder, AppleScript).
    static func emptyTrash() async -> Result {
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        do { try proc.run(); proc.waitUntilExit() } catch {
            return .init(title: "Trash", bytesFreed: 0, success: false,
                         message: "\(error.localizedDescription)")
        }
        return .init(title: "Trash", bytesFreed: 0, success: true, message: "Emptied")
    }

    /// Moves an item to the Trash (recoverable).
    @discardableResult
    static func moveToTrash(_ path: String) -> Error? {
        let url = URL(fileURLWithPath: path)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return nil
        } catch {
            return error
        }
    }
}
