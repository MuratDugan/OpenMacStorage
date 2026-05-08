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
        }
    }
}

/// Verilen yola göre kategori tahmini yapar.
enum CategoryClassifier {
    static func classify(path: String, isDirectory: Bool) -> StorageCategory {
        let p = path

        // Uygulamalar
        if p.hasPrefix("/Applications") || p.hasPrefix("/System/Applications") { return .applications }

        // Xcode / geliştirici
        if p.contains("/Library/Developer/Xcode/DerivedData") ||
           p.contains("/Library/Developer/Xcode/iOS DeviceSupport") ||
           p.contains("/Library/Developer/Xcode/watchOS DeviceSupport") ||
           p.contains("/Library/Developer/Xcode/tvOS DeviceSupport") ||
           p.contains("/Library/Developer/Xcode/Archives") ||
           p.contains("/Library/Developer/CoreSimulator") ||
           p.contains("/Library/Developer/Toolchains") ||
           p.hasSuffix(".xcarchive") {
            return .developerXcode
        }

        // VM imajları (Docker, OrbStack, Parallels, UTM, VMware)
        if p.contains("/.docker/") ||
           p.contains("/Library/Containers/com.docker.") ||
           p.contains("/.orbstack/") ||
           p.contains("/Library/Group Containers/group.com.docker") ||
           p.contains("/Parallels/") ||
           p.contains("/UTM/") ||
           p.hasSuffix(".vmwarevm") || p.hasSuffix(".pvm") {
            return .developerVMs
        }

        // Önbellekler
        if p.contains("/Library/Caches") { return .caches }

        // Loglar
        if p.contains("/Library/Logs") || p.hasPrefix("/var/log") || p.hasPrefix("/private/var/log") {
            return .logs
        }

        // Mail
        if p.contains("/Library/Mail") || p.contains("/Library/Containers/com.apple.mail") {
            return .mail
        }

        // Fotoğraflar
        if p.hasSuffix(".photoslibrary") || p.contains("/Pictures/Photos Library") {
            return .photos
        }

        // İndirilenler / Belgeler / Çöp
        if p.contains("/Downloads/") || p.hasSuffix("/Downloads") { return .downloads }
        if p.contains("/.Trash") || p.contains("/.Trashes") { return .trash }
        if p.contains("/Documents/") { return .documents }

        // iCloud
        if p.contains("/Library/Mobile Documents") || p.contains("CloudDocs") {
            return .iCloud
        }

        // Sistem (root)
        if p.hasPrefix("/System") || p.hasPrefix("/private/var/db") || p.hasPrefix("/usr") {
            return .systemReserved
        }

        return .other
    }
}
