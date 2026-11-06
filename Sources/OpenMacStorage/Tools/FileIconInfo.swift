import SwiftUI

/// Maps a `FileNode` to a visually distinctive SF Symbol + colour pair so the
/// folder browser, search results, and duplicates all use the same iconography
/// and the eye can tell file kinds apart at a glance.
struct FileIconInfo: Equatable {
    let symbol: String
    let color: Color

    static func forNode(_ node: FileNode) -> FileIconInfo {
        if node.isDirectory {
            // Folders always look like folders. A constant warm-blue is the
            // strongest visual cue that "this is a folder" — everything else
            // varies by file type.
            return .init(symbol: "folder.fill",
                         color: Color(red: 0.30, green: 0.60, blue: 1.00))
        }
        return forExtension((node.name as NSString).pathExtension.lowercased())
    }

    /// Public so other views (OldFiles, FileTypeStats) can reuse it.
    static func forExtension(_ ext: String) -> FileIconInfo {
        switch ext {
        // Video
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "flv":
            return .init(symbol: "film.fill", color: .purple)
        // Audio
        case "mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "aiff":
            return .init(symbol: "music.note", color: .pink)
        // Images
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp", "bmp", "raw":
            return .init(symbol: "photo.fill", color: .green)
        // Design
        case "psd", "ai", "sketch", "fig", "xd", "afphoto", "afdesign":
            return .init(symbol: "paintbrush.fill", color: .blue)
        // PDF
        case "pdf":
            return .init(symbol: "doc.richtext.fill", color: .red)
        // Archives
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .init(symbol: "doc.zipper", color: .yellow)
        // Disk images
        case "dmg", "iso", "img":
            return .init(symbol: "opticaldisc.fill", color: .gray)
        // Word-ish
        case "doc", "docx", "rtf", "pages", "odt":
            return .init(symbol: "doc.text.fill", color: .blue)
        // Spreadsheets
        case "xls", "xlsx", "csv", "tsv", "numbers", "ods":
            return .init(symbol: "tablecells.fill", color: .green)
        // Presentations
        case "ppt", "pptx", "key", "odp":
            return .init(symbol: "rectangle.stack.fill", color: .orange)
        // Source code
        case "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java",
             "kt", "c", "cpp", "cc", "h", "hpp", "rb", "php", "lua", "sh":
            return .init(symbol: "chevron.left.forwardslash.chevron.right", color: .orange)
        // Web
        case "html", "htm", "css", "scss", "sass", "less":
            return .init(symbol: "globe", color: .cyan)
        // Structured data
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return .init(symbol: "curlybraces", color: .teal)
        // Plain text / logs / markdown
        case "log", "txt", "md", "markdown", "rst":
            return .init(symbol: "doc.plaintext.fill", color: .secondary)
        // Apps
        case "app":
            return .init(symbol: "app.fill", color: .blue)
        // Databases
        case "sqlite", "sqlitedb", "db":
            return .init(symbol: "cylinder.fill", color: .indigo)
        // Game ROMs
        case "nsp", "xci", "nca", "wbfs":
            return .init(symbol: "gamecontroller.fill", color: .red)
        // Fonts
        case "ttf", "otf", "woff", "woff2":
            return .init(symbol: "textformat", color: .indigo)
        // E-books
        case "epub", "mobi", "azw", "azw3":
            return .init(symbol: "book.fill", color: .brown)
        // Default file
        default:
            return .init(symbol: "doc.fill", color: .secondary)
        }
    }

    /// Localized human description of what kind of file this is — the value
    /// shown in the "Kind" column of the browser & search.
    static func kindLabel(for node: FileNode) -> String {
        if node.isDirectory { return String(localized: "Folder") }
        return kindLabel(forExtension: (node.name as NSString).pathExtension.lowercased())
    }

    static func kindLabel(forExtension ext: String) -> String {
        let key: String.LocalizationValue
        switch ext {
        // Office-style documents
        case "docx", "doc":   key = "Word document"
        case "xlsx", "xls":   key = "Excel spreadsheet"
        case "pptx", "ppt":   key = "PowerPoint presentation"
        case "pages":         key = "Pages document"
        case "numbers":       key = "Numbers spreadsheet"
        case "key":           key = "Keynote presentation"
        case "rtf":           key = "Rich text"
        case "odt":           key = "OpenDocument text"
        case "ods":           key = "OpenDocument spreadsheet"
        case "odp":           key = "OpenDocument presentation"

        // PDFs / text
        case "pdf":           key = "PDF document"
        case "txt":           key = "Text"
        case "md", "markdown": key = "Markdown"
        case "log":           key = "Log file"
        case "csv":           key = "CSV data"
        case "tsv":           key = "TSV data"

        // Images
        case "png":           key = "PNG image"
        case "jpg", "jpeg":   key = "JPEG image"
        case "heic":          key = "HEIC image"
        case "gif":           key = "GIF image"
        case "tiff", "tif":   key = "TIFF image"
        case "webp":          key = "WebP image"
        case "bmp":           key = "Bitmap image"
        case "svg":           key = "SVG image"
        case "raw":           key = "Camera RAW"

        // Design files
        case "psd":           key = "Photoshop"
        case "ai":            key = "Illustrator"
        case "sketch":        key = "Sketch"
        case "fig":           key = "Figma"
        case "xd":            key = "Adobe XD"
        case "afphoto":       key = "Affinity Photo"
        case "afdesign":      key = "Affinity Designer"

        // Video
        case "mp4":           key = "MP4 video"
        case "mov":           key = "QuickTime video"
        case "mkv":           key = "Matroska video"
        case "avi":           key = "AVI video"
        case "webm":          key = "WebM video"
        case "m4v":           key = "iTunes video"
        case "flv":           key = "Flash video"

        // Audio
        case "mp3":           key = "MP3 audio"
        case "wav":           key = "WAV audio"
        case "flac":          key = "FLAC audio"
        case "m4a":           key = "M4A audio"
        case "aac":           key = "AAC audio"
        case "ogg", "opus":   key = "OGG audio"
        case "aiff":          key = "AIFF audio"

        // Archives
        case "zip":           key = "ZIP archive"
        case "rar":           key = "RAR archive"
        case "7z":            key = "7-Zip archive"
        case "tar":           key = "TAR archive"
        case "gz", "bz2", "xz": key = "Compressed archive"

        // Disk images
        case "dmg":           key = "macOS disk image"
        case "iso":           key = "ISO image"
        case "img":           key = "Disk image"

        // Web / data
        case "html", "htm":   key = "Web page"
        case "css":           key = "Stylesheet"
        case "scss", "sass", "less": key = "CSS preprocessor"
        case "json":          key = "JSON data"
        case "yaml", "yml":   key = "YAML data"
        case "toml":          key = "TOML data"
        case "xml":           key = "XML data"
        case "plist":         key = "Property list"

        // Source code
        case "swift":         key = "Swift source"
        case "py":            key = "Python source"
        case "rb":            key = "Ruby source"
        case "js":            key = "JavaScript source"
        case "ts":            key = "TypeScript source"
        case "tsx":           key = "TypeScript React"
        case "jsx":           key = "JavaScript React"
        case "go":            key = "Go source"
        case "rs":            key = "Rust source"
        case "java":          key = "Java source"
        case "kt":            key = "Kotlin source"
        case "c":             key = "C source"
        case "cpp", "cc":     key = "C++ source"
        case "h":             key = "C header"
        case "hpp":           key = "C++ header"
        case "sh", "bash", "zsh": key = "Shell script"
        case "php":           key = "PHP source"
        case "lua":           key = "Lua source"

        // Apps & databases
        case "app":           key = "Application"
        case "ipa":           key = "iOS app"
        case "sqlite", "sqlitedb", "db": key = "Database"

        // Fonts
        case "ttf":           key = "TrueType font"
        case "otf":           key = "OpenType font"
        case "woff", "woff2": key = "Web font"

        // E-books
        case "epub":          key = "EPUB book"
        case "mobi", "azw", "azw3": key = "Kindle book"

        // Game ROMs
        case "nsp", "xci", "nca", "wbfs": key = "Switch ROM"

        case "":              key = "File (no extension)"
        default:              return ".\(ext.uppercased())"
        }
        return String(localized: key)
    }

    // MARK: - Kind groups (used by the browser's Type filter)

    enum KindGroup: String, CaseIterable, Identifiable, Hashable {
        case all, folders, documents, images, videos, audio,
             archives, code, disks, applications, hidden, files, cloudOnly
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .all:          "All items"
            case .folders:      "Folders only"
            case .files:        "Any file"
            case .documents:    "Documents"
            case .images:       "Images"
            case .videos:       "Videos"
            case .audio:        "Audio"
            case .archives:     "Archives"
            case .code:         "Source code"
            case .disks:        "Disk images"
            case .applications: "Applications"
            case .hidden:       "Hidden items"
            case .cloudOnly:    "Only in the cloud"
            }
        }
        var icon: String {
            switch self {
            case .all:          "square.grid.2x2"
            case .folders:      "folder.fill"
            case .files:        "doc.fill"
            case .documents:    "doc.text.fill"
            case .images:       "photo.fill"
            case .videos:       "film.fill"
            case .audio:        "music.note"
            case .archives:     "doc.zipper"
            case .code:         "chevron.left.forwardslash.chevron.right"
            case .disks:        "opticaldisc.fill"
            case .applications: "app.fill"
            case .hidden:       "eye.slash.fill"
            case .cloudOnly:    "icloud"
            }
        }

        private static let documentExts: Set<String> = [
            "doc","docx","pages","odt","rtf","pdf","txt","md","markdown",
            "xls","xlsx","numbers","ods","csv","tsv","ppt","pptx","key","odp"]
        private static let imageExts: Set<String> = [
            "png","jpg","jpeg","heic","gif","tiff","tif","webp","bmp",
            "svg","raw","psd","ai","sketch","fig","xd"]
        private static let videoExts: Set<String> = ["mp4","mov","mkv","avi","webm","m4v","flv"]
        private static let audioExts: Set<String> = ["mp3","wav","flac","m4a","aac","ogg","opus","aiff"]
        private static let archiveExts: Set<String> = ["zip","rar","7z","tar","gz","bz2","xz"]
        private static let codeExts: Set<String> = [
            "swift","py","rb","js","ts","tsx","jsx","go","rs","java","kt",
            "c","cpp","cc","h","hpp","sh","bash","zsh","php","lua",
            "html","htm","css","scss","sass","less","json","yaml","yml",
            "toml","xml","plist"]
        private static let diskExts: Set<String> = ["dmg","iso","img"]

        func matches(_ node: FileNode) -> Bool {
            switch self {
            case .all:          return true
            case .folders:      return node.isDirectory
            case .files:        return !node.isDirectory
            case .hidden:       return node.isHiddenFile
            case .cloudOnly:    return node.cloudSize > 0
            default:            break
            }
            guard !node.isDirectory else { return false }
            let ext = (node.name as NSString).pathExtension.lowercased()
            switch self {
            case .documents:    return Self.documentExts.contains(ext)
            case .images:       return Self.imageExts.contains(ext)
            case .videos:       return Self.videoExts.contains(ext)
            case .audio:        return Self.audioExts.contains(ext)
            case .archives:     return Self.archiveExts.contains(ext)
            case .code:         return Self.codeExts.contains(ext)
            case .disks:        return Self.diskExts.contains(ext)
            case .applications: return ext == "app" || ext == "ipa"
            default:
                return false
            }
        }
    }
}
