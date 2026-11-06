import Foundation
import AppKit

/// Detects whether the app has been granted Full Disk Access and helps the
/// user grant it.
///
/// Why this matters: without FDA, macOS TCC throws a separate consent prompt
/// for *every* protected folder the scanner touches (Desktop, Documents,
/// Downloads, Photos, Mail, per-app containers…) and silently returns empty
/// results for the rest. With FDA there are zero prompts and the scan is
/// complete.
enum FullDiskAccess {

    /// True when the app can read TCC-protected locations.
    ///
    /// Technique: try to actually open/list files that macOS only exposes to
    /// processes holding the "Full Disk Access" entitlement grant. We probe
    /// several so the check is robust across macOS versions and setups.
    static func isGranted() -> Bool {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // Directory probes — listing succeeds only with FDA.
        let dirProbes = [
            "\(home)/Library/Safari",
            "\(home)/Library/Mail",
            "\(home)/Library/Containers/com.apple.Safari/Data"
        ]
        for dir in dirProbes {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                if (try? fm.contentsOfDirectory(atPath: dir)) != nil { return true }
            }
        }

        // File probes — the TCC databases always exist and are unreadable
        // without FDA.
        let fileProbes = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
        for file in fileProbes {
            if let handle = FileHandle(forReadingAtPath: file) {
                try? handle.close()
                return true
            }
        }
        return false
    }

    /// Jumps straight to System Settings → Privacy & Security → Full Disk
    /// Access.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveals the app bundle in Finder so the user can drag it into the FDA
    /// list if it isn't already there.
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Cleanly relaunches the app — TCC grants are evaluated per-process, so
    /// a restart guarantees the scanner sees the new permission.
    ///
    /// AppKit refuses to terminate (and beeps) while a window has a sheet
    /// attached, so sheets are dismissed first. A small helper waits until
    /// this process has really exited before reopening the bundle — otherwise
    /// `open` would just re-activate the still-running instance.
    @MainActor
    static func restartApp() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            path]
        try? task.run()

        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        // Last resort if something still vetoes termination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(0) }
    }
}
