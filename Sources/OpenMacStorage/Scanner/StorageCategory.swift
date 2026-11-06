import SwiftUI

enum StorageCategory: String, CaseIterable, Sendable, Hashable {
    case applications     = "Applications"
    case developerXcode   = "Xcode & Developer"
    case developerVMs     = "Virtual Machines"
    case caches           = "Caches"
    case logs             = "Logs"
    case mail             = "Mail"
    case photos           = "Photos"
    case music            = "Music"
    case videos           = "Videos"
    case documents        = "Documents"
    case downloads        = "Downloads"
    case trash            = "Trash"
    case snapshots        = "APFS Snapshots"
    case systemReserved   = "macOS System"
    case iCloud           = "iCloud Drive"
    case other            = "Other"
    // Appended (archives store the case index — never reorder the above).
    case appData          = "App Data"
    case cloudDrives      = "Cloud Drives"

    /// Localized display name (uses Localizable.strings).
    var localizedName: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(rawValue))
    }

    /// Hand-picked palette tuned for dark-mode treemap legibility.
    /// Vivid enough to read against black, harmonised so neighbours don't clash.
    var color: Color {
        switch self {
        case .applications:    Color(red: 1.00, green: 0.55, blue: 0.16)   // Vivid orange
        case .developerXcode:  Color(red: 1.00, green: 0.78, blue: 0.18)   // Amber gold
        case .developerVMs:    Color(red: 0.78, green: 0.48, blue: 0.22)   // Warm sienna
        case .caches:          Color(red: 0.62, green: 0.66, blue: 0.74)   // Cool gray
        case .logs:            Color(red: 0.48, green: 0.52, blue: 0.60)   // Slate
        case .mail:            Color(red: 0.20, green: 0.60, blue: 1.00)   // Sky blue
        case .photos:          Color(red: 0.18, green: 0.78, blue: 0.42)   // Emerald
        case .music:           Color(red: 0.95, green: 0.32, blue: 0.55)   // Hot pink
        case .videos:          Color(red: 0.62, green: 0.36, blue: 0.96)   // Vivid purple
        case .documents:       Color(red: 0.94, green: 0.32, blue: 0.32)   // Coral red
        case .downloads:       Color(red: 0.18, green: 0.78, blue: 0.86)   // Cyan
        case .trash:           Color(red: 0.55, green: 0.52, blue: 0.50)   // Warm gray
        case .snapshots:       Color(red: 0.42, green: 0.46, blue: 0.96)   // Indigo
        case .systemReserved:  Color(red: 0.28, green: 0.86, blue: 0.66)   // Mint
        case .iCloud:          Color(red: 0.20, green: 0.74, blue: 0.78)   // Teal
        case .other:           Color(red: 0.52, green: 0.56, blue: 0.62)   // Neutral
        case .appData:         Color(red: 0.36, green: 0.58, blue: 0.92)   // Steel blue
        case .cloudDrives:     Color(red: 0.46, green: 0.80, blue: 0.96)   // Pale sky
        }
    }

    var symbol: String {
        switch self {
        case .applications:    "app.badge"
        case .developerXcode:  "hammer.fill"
        case .developerVMs:    "macwindow.on.rectangle"
        case .caches:          "tray.full.fill"
        case .logs:            "doc.text.magnifyingglass"
        case .mail:            "envelope.fill"
        case .photos:          "photo.stack"
        case .music:           "music.note"
        case .videos:          "film.stack"
        case .documents:       "doc.fill"
        case .downloads:       "arrow.down.circle.fill"
        case .trash:           "trash.fill"
        case .snapshots:       "clock.arrow.circlepath"
        case .systemReserved:  "gearshape.2.fill"
        case .iCloud:          "icloud.fill"
        case .other:           "questionmark.folder"
        case .appData:         "shippingbox.fill"
        case .cloudDrives:     "externaldrive.fill.badge.icloud"
        }
    }
}

/// Path → category. The scanner only calls this while the parent is still
/// `.other`; once a folder gets a category its whole subtree inherits it, so
/// rules must be written for the *folder* that starts a category.
enum CategoryClassifier {
    private static let home = NSHomeDirectory()

    /// Developer tool caches and package stores in the home folder.
    private static let devHomeFolders: Set<String> = [
        ".npm", ".yarn", ".pnpm-store", ".bun", ".cache", ".cargo", ".rustup",
        ".gradle", ".m2", ".pyenv", ".nvm", ".conda", ".gem", ".cocoapods",
        ".android", ".swiftpm", ".deno", ".ollama", ".lmstudio", "go"
    ]

    static func classify(path: String, isDirectory: Bool) -> StorageCategory {
        let p = path
        let name = (p as NSString).lastPathComponent

        // Dependency / build folders anywhere (node_modules, .venv, DerivedData…).
        if isDirectory, FastScanner.isDevArtifact(name: name) { return .developerXcode }

        // Applications
        if p.hasPrefix("/Applications") || p.hasPrefix("/System/Applications") { return .applications }
        if isDirectory, name.hasSuffix(".app") { return .applications }

        // Xcode / developer
        if p.contains("/Library/Developer/") || p.hasSuffix("/Library/Developer") ||
           p.hasSuffix(".xcarchive") ||
           p.hasPrefix("/opt/homebrew") || p.hasPrefix("/usr/local") ||
           p.hasPrefix("/Library/Developer") {
            return .developerXcode
        }
        if isDirectory, p.hasPrefix(home), (p as NSString).deletingLastPathComponent == home,
           devHomeFolders.contains(name) {
            return .developerXcode
        }

        // VM images (Docker, OrbStack, Parallels, UTM, VMware)
        if p.contains("/.docker/") || p.hasSuffix("/.docker") ||
           p.contains("/Library/Containers/com.docker.") ||
           p.contains("/.orbstack") ||
           p.contains("/Library/Group Containers/group.com.docker") ||
           p.contains("/Parallels") ||
           p.contains("/Containers/com.utmapp.") || p.contains("/UTM/") ||
           p.hasSuffix(".vmwarevm") || p.hasSuffix(".pvm") || p.hasSuffix(".utm") {
            return .developerVMs
        }

        // Caches & temp
        if p.contains("/Library/Caches") || p.hasPrefix("/private/var/folders") { return .caches }

        // Logs
        if p.contains("/Library/Logs") || p.hasPrefix("/var/log") || p.hasPrefix("/private/var/log") {
            return .logs
        }

        // Mail
        if p.contains("/Library/Mail") || p.contains("/Library/Containers/com.apple.mail") {
            return .mail
        }

        // Cloud drives (File Provider: Nextcloud, Google Drive, OneDrive, Dropbox…)
        if p.contains("/Library/CloudStorage") { return .cloudDrives }

        // iCloud Drive
        if p.contains("/Library/Mobile Documents") { return .iCloud }

        // Trash
        if p.contains("/.Trash") { return .trash }

        // Media & user folders (home-level only — avoids matching e.g. a
        // "Documents" folder inside an app container).
        if p.hasPrefix(home) {
            if p.hasSuffix(".photoslibrary") || p.hasPrefix(home + "/Pictures") { return .photos }
            if p.hasPrefix(home + "/Music") { return .music }
            if p.hasPrefix(home + "/Movies") { return .videos }
            if p.hasPrefix(home + "/Downloads") { return .downloads }
            if p.hasPrefix(home + "/Documents") || p.hasPrefix(home + "/Desktop") { return .documents }
        } else if p.hasSuffix(".photoslibrary") {
            return .photos
        }

        // App data: support files, sandbox containers, Messages, etc.
        if p.contains("/Library/Application Support") ||
           p.contains("/Library/Containers") ||
           p.contains("/Library/Group Containers") ||
           p.contains("/Library/Messages") {
            return .appData
        }

        // System
        if p.hasPrefix("/System") || p.hasPrefix("/private/var/db") || p.hasPrefix("/usr") ||
           p.hasPrefix("/bin") || p.hasPrefix("/sbin") || p.hasPrefix("/Library/Apple") {
            return .systemReserved
        }

        return .other
    }
}
