import Foundation

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
