import Foundation

/// `/Applications/X.app` için kullanıcı kütüphanesindeki yan dosyaları bulan
/// kaldırıcı. Çoğu macOS uygulaması temizlik bırakmadığından bu değerli.
struct AppRelatedFile: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let size: Int64
    let category: String   // "Application Support", "Caches", etc. — used as LocalizedStringKey.
}

struct AppUninstallReport: Sendable {
    let appPath: String
    let bundleId: String?
    let appName: String
    let appSize: Int64
    let related: [AppRelatedFile]
    var totalSize: Int64 { appSize + related.reduce(0) { $0 + $1.size } }
}

enum AppUninstaller {

    /// `/Applications` (ya da herhangi bir .app) altındaki uygulamayı analiz eder.
    static func analyze(appPath: String) async -> AppUninstallReport {
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleId = readBundleId(at: appPath)
        let appSize = await directorySize(at: appPath)

        let home = NSString(string: "~").expandingTildeInPath
        let searchRoots: [(String, String)] = [
            ("\(home)/Library/Application Support", "Application Support"),
            ("\(home)/Library/Caches", "Caches"),
            ("\(home)/Library/Containers", "Container"),
            ("\(home)/Library/Group Containers", "Group Container"),
            ("\(home)/Library/Preferences", "Preferences"),
            ("\(home)/Library/Logs", "Logs"),
            ("\(home)/Library/Saved Application State", "Saved State"),
            ("\(home)/Library/HTTPStorages", "HTTP Storage"),
            ("\(home)/Library/WebKit", "WebKit"),
            ("\(home)/Library/Cookies", "Cookies"),
            ("/Library/Application Support", "System Application Support"),
            ("/Library/Caches", "System Caches"),
            ("/Library/Logs", "System Logs"),
            ("/Library/Preferences", "System Preferences")
        ]

        var related: [AppRelatedFile] = []
        for (root, category) in searchRoots {
            related.append(contentsOf: findRelated(in: root, name: name, bundleId: bundleId, category: category))
        }
        related.sort { $0.size > $1.size }
        return AppUninstallReport(appPath: appPath,
                                  bundleId: bundleId,
                                  appName: name,
                                  appSize: appSize,
                                  related: related)
    }

    private static func findRelated(in root: String, name: String, bundleId: String?, category: String) -> [AppRelatedFile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var matches: [AppRelatedFile] = []
        for entry in entries {
            let lower = entry.lowercased()
            let matchesName = lower.contains(name.lowercased())
            let matchesBundle = bundleId.map { lower.contains($0.lowercased()) } ?? false
            guard matchesName || matchesBundle else { continue }
            let p = (root as NSString).appendingPathComponent(entry)
            let size = directorySizeSync(at: p)
            matches.append(.init(path: p, size: size, category: category))
        }
        return matches
    }

    private static func readBundleId(at appPath: String) -> String? {
        let plist = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plist)),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    private static func directorySize(at path: String) async -> Int64 {
        await Task.detached(priority: .userInitiated) {
            directorySizeSync(at: path)
        }.value
    }

    private static func directorySizeSync(at path: String) -> Int64 {
        SystemDataAnalyzer.directorySize(at: path)
    }

    /// Uygulamayı + seçili yan dosyaları çöpe atar.
    static func uninstall(report: AppUninstallReport, includeRelated: Set<UUID>) -> [String: Error] {
        var failures: [String: Error] = [:]
        if let err = CleanupActions.moveToTrash(report.appPath) {
            failures[report.appPath] = err
        }
        for r in report.related where includeRelated.contains(r.id) {
            if let err = CleanupActions.moveToTrash(r.path) {
                failures[r.path] = err
            }
        }
        return failures
    }
}
