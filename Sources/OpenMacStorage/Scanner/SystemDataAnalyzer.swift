import Foundation

/// Demystifies macOS's "System Data" bucket. For most users this category contains:
///   • APFS local snapshots (Time Machine local)
///   • Xcode DerivedData / iOS DeviceSupport / Simulators
///   • Docker / OrbStack VM images
///   • ~/Library/Caches, /Library/Caches
///   • Mail downloads
///   • sleep image, swap, .Spotlight-V100
struct SystemDataReport: Sendable {
    struct Bucket: Identifiable, Sendable {
        let id = UUID()
        let title: LocalizedStringResource
        let path: String?
        let bytes: Int64
        let detail: LocalizedStringResource
        let cleanable: Bool
    }
    var buckets: [Bucket]
    var totalBytes: Int64 { buckets.reduce(0) { $0 + $1.bytes } }
}

enum SystemDataAnalyzer {

    static func analyze() async -> SystemDataReport {
        await withTaskGroup(of: SystemDataReport.Bucket?.self, returning: SystemDataReport.self) { group in
            group.addTask { snapshotsBucket() }
            group.addTask { sizeBucket(title: "Xcode DerivedData",
                                       path: NSString(string: "~/Library/Developer/Xcode/DerivedData").expandingTildeInPath,
                                       detail: "Xcode build cache. Safe to delete — Xcode regenerates it on next build.",
                                       cleanable: true) }
            group.addTask { sizeBucket(title: "iOS Device Support",
                                       path: NSString(string: "~/Library/Developer/Xcode/iOS DeviceSupport").expandingTildeInPath,
                                       detail: "Symbols for old iOS versions. Safe to delete for devices you no longer use.",
                                       cleanable: true) }
            group.addTask { sizeBucket(title: "iOS Simulators",
                                       path: NSString(string: "~/Library/Developer/CoreSimulator").expandingTildeInPath,
                                       detail: "Simulator device images. Unused ones can be cleaned with `xcrun simctl delete unavailable`.",
                                       cleanable: true) }
            group.addTask { sizeBucket(title: "Xcode Archives",
                                       path: NSString(string: "~/Library/Developer/Xcode/Archives").expandingTildeInPath,
                                       detail: "App Store distribution archives. Safe to delete once published.",
                                       cleanable: true) }
            group.addTask { sizeBucket(title: "User Caches",
                                       path: NSString(string: "~/Library/Caches").expandingTildeInPath,
                                       detail: "Per-app caches. Generally safe to delete; apps will rebuild them.",
                                       cleanable: true) }
            group.addTask { sizeBucket(title: "System Caches",
                                       path: "/Library/Caches",
                                       detail: "System-wide caches.",
                                       cleanable: false) }
            group.addTask { sizeBucket(title: "Docker Desktop VM",
                                       path: NSString(string: "~/Library/Containers/com.docker.docker").expandingTildeInPath,
                                       detail: "Docker Desktop virtual disk image. Tends to grow large.",
                                       cleanable: false) }
            group.addTask { sizeBucket(title: "OrbStack",
                                       path: NSString(string: "~/.orbstack").expandingTildeInPath,
                                       detail: "OrbStack VM and container disk images.",
                                       cleanable: false) }
            group.addTask { sizeBucket(title: "Mail",
                                       path: NSString(string: "~/Library/Mail").expandingTildeInPath,
                                       detail: "Downloaded email attachments. Going offline in Mail.app shrinks this.",
                                       cleanable: false) }
            group.addTask { sizeBucket(title: "Logs",
                                       path: NSString(string: "~/Library/Logs").expandingTildeInPath,
                                       detail: "Application log files.",
                                       cleanable: true) }
            group.addTask { sleepImageBucket() }

            var buckets: [SystemDataReport.Bucket] = []
            for await b in group { if let b { buckets.append(b) } }
            buckets.sort { $0.bytes > $1.bytes }
            return SystemDataReport(buckets: buckets)
        }
    }

    // MARK: - Helpers

    private static func sizeBucket(title: String.LocalizationValue,
                                   path: String,
                                   detail: String.LocalizationValue,
                                   cleanable: Bool) -> SystemDataReport.Bucket? {
        let bytes = directorySize(at: path)
        guard bytes > 0 else { return nil }
        return .init(title: LocalizedStringResource(title),
                     path: path,
                     bytes: bytes,
                     detail: LocalizedStringResource(detail),
                     cleanable: cleanable)
    }

    private static func snapshotsBucket() -> SystemDataReport.Bucket? {
        let snapshots = APFSSnapshots.list()
        guard !snapshots.isEmpty else { return nil }
        return .init(title: "APFS Local Snapshots",
                     path: "/",
                     bytes: 0,
                     detail: "\(snapshots.count) local snapshots. Delete with `tmutil deletelocalsnapshots`.",
                     cleanable: true)
    }

    private static func sleepImageBucket() -> SystemDataReport.Bucket? {
        let p = "/private/var/vm/sleepimage"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attrs[.size] as? Int64, size > 0 else { return nil }
        return .init(title: "Sleep Image",
                     path: p,
                     bytes: size,
                     detail: "RAM contents during sleep. Not recommended to delete — system regenerates it.",
                     cleanable: false)
    }

    /// Directory total size (recursive, on-disk).
    static func directorySize(at path: String) -> Int64 {
        FastScanner.measure(path: path)
    }
}

/// Lists local APFS snapshots via `tmutil`.
enum APFSSnapshots {
    struct Snapshot: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let date: Date?
    }

    static func list() -> [Snapshot] {
        let proc = Process()
        proc.launchPath = "/usr/bin/tmutil"
        proc.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("com.apple.TimeMachine.") else { return nil }
            let suffix = s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                          .replacingOccurrences(of: ".local", with: "")
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            return Snapshot(name: s, date: f.date(from: suffix))
        }
    }

    static func deleteAll() {
        let proc = Process()
        proc.launchPath = "/usr/bin/tmutil"
        proc.arguments = ["deletelocalsnapshots", "/"]
        try? proc.run()
        proc.waitUntilExit()
    }
}
