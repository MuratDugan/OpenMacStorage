import SwiftUI

/// Classifies how dangerous it is to delete a given path. Used by the browser
/// to colour-tag rows and gate the delete flow with appropriate confirmation.
struct RiskAssessment: Sendable {
    enum Level: Int, Sendable, Comparable {
        case none = 0       // user-owned files: documents, downloads, projects
        case low            // cache-like: rebuilt automatically (Caches, DerivedData)
        case medium         // could lose preferences / app data, but recoverable from app
        case high           // likely breaks an installed app
        case blocked        // macOS-managed; refuse to delete

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    let level: Level
    /// User-facing reason. Localized via the bundle.
    let reason: LocalizedStringResource

    static let safe = RiskAssessment(level: .none, reason: "")

    var color: Color {
        switch level {
        case .none:    .secondary
        case .low:     .blue
        case .medium:  .orange
        case .high:    .red
        case .blocked: .purple
        }
    }

    var icon: String {
        switch level {
        case .none:    "checkmark.seal.fill"
        case .low:     "info.circle.fill"
        case .medium:  "exclamationmark.triangle.fill"
        case .high:    "exclamationmark.octagon.fill"
        case .blocked: "lock.shield.fill"
        }
    }

    var label: LocalizedStringResource {
        switch level {
        case .none:    "Safe"
        case .low:     "Cache"
        case .medium:  "App data"
        case .high:    "App will break"
        case .blocked: "Protected"
        }
    }
}

enum RiskClassifier {
    /// Classifies a path's deletion risk.
    static func assess(_ path: String) -> RiskAssessment {
        // Hard-blocked: deleting these can corrupt macOS.
        if path.hasPrefix("/System") { return blocked("System file — deleting could break macOS itself.") }
        if path.hasPrefix("/private/var/db") { return blocked("System database — never delete.") }
        if path.hasPrefix("/private/etc") { return blocked("System config — never delete.") }
        if path.hasPrefix("/usr") || path.hasPrefix("/bin") || path.hasPrefix("/sbin") {
            return blocked("System binary — never delete.")
        }
        if path.contains("/Cryptexes") || path.contains("/Library/CryptexLibrary") {
            return blocked("Sealed system volume — never delete.")
        }
        if path.contains("/Preboot/") {
            return blocked("Boot data — deleting prevents macOS from starting.")
        }
        if path.contains("/Library/Apple/") {
            return blocked("Apple system data — never delete.")
        }
        if path.hasPrefix("/Volumes/") && !path.contains("/Volumes/Macintosh HD") {
            return medium("External volume — make sure you're deleting the right thing.")
        }

        // High risk: cloud-synced folders. Trashing a file here removes it
        // from the cloud and from every other synced device too.
        if path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/") {
            return high("Cloud-synced — deleting removes it from the cloud and your other devices.")
        }

        // High risk: likely breaks the app this belongs to.
        if path.contains("/Library/Containers/") {
            return high("App container — the owning app will lose its data.")
        }
        if path.contains("/Library/Group Containers/") {
            return high("Shared app data — multiple apps may be affected.")
        }
        if path.contains("/Library/Application Support/") &&
            !path.contains("/Library/Application Support/CrashReporter") {
            return high("App data — settings, accounts, projects may be lost.")
        }
        if path.contains("/Library/Frameworks/") || path.contains("/Library/PreferencePanes/") {
            return high("System extension — apps depending on it will fail.")
        }
        if path.hasSuffix(".app") && path.hasPrefix("/Applications") {
            return medium("Application bundle — better to use the Uninstall App tool.")
        }

        // Medium risk: preferences, small data
        if path.contains("/Library/Preferences/") {
            return medium("App preferences — the app will reset to defaults.")
        }
        if path.contains("/Library/Saved Application State/") {
            return low("Saved window state — apps will reopen with default layout.")
        }

        // Low risk: caches, dev artefacts, logs
        if path.contains("/Library/Caches/") {
            return low("Cache — apps will rebuild it automatically.")
        }
        if path.contains("/Library/Developer/Xcode/DerivedData") {
            return low("Xcode build cache — regenerated on next build.")
        }
        if path.contains("/Library/Developer/Xcode/Archives") {
            return low("Xcode archive — only needed if redistributing the app.")
        }
        if path.contains("/Library/Developer/CoreSimulator") {
            return low("iOS simulator data — large but easy to regenerate.")
        }
        if path.contains("/Library/Logs/") {
            return low("Log file — purely informational.")
        }
        if path.contains("/Library/HTTPStorages/") || path.contains("/Library/WebKit/") ||
            path.contains("/Library/Cookies/") {
            return low("Web cache / cookies — sites will need re-login.")
        }

        // Anything else under /Library is a default medium since user usually
        // doesn't poke around there knowingly.
        if path.hasPrefix("/Library/") { return medium("System library item.") }

        // Hidden dotfiles in home that look like dev caches:
        if path.contains("/.Trash/") { return .safe }
        if path.contains("/node_modules") || path.contains("/.next") ||
           path.contains("/.cache") || path.contains("/__pycache__") {
            return low("Dev artefact — regenerated by your tooling.")
        }

        return .safe
    }

    // MARK: - Convenience constructors

    private static func blocked(_ reason: String.LocalizationValue) -> RiskAssessment {
        .init(level: .blocked, reason: LocalizedStringResource(reason))
    }
    private static func high(_ reason: String.LocalizationValue) -> RiskAssessment {
        .init(level: .high, reason: LocalizedStringResource(reason))
    }
    private static func medium(_ reason: String.LocalizationValue) -> RiskAssessment {
        .init(level: .medium, reason: LocalizedStringResource(reason))
    }
    private static func low(_ reason: String.LocalizationValue) -> RiskAssessment {
        .init(level: .low, reason: LocalizedStringResource(reason))
    }
}
