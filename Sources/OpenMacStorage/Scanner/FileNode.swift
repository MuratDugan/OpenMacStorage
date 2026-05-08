import Foundation

final class FileNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var size: Int64           // kendi başına (dosya: dosya boyutu, dizin: alt toplam)
    var ownSize: Int64        // sadece kendisi (dizin için 0)
    var fileCount: Int
    var dirCount: Int
    var children: [FileNode]
    weak var parent: FileNode?
    var category: StorageCategory

    init(name: String,
         path: String,
         isDirectory: Bool,
         ownSize: Int64 = 0,
         category: StorageCategory = .other) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.ownSize = ownSize
        self.size = ownSize
        self.fileCount = isDirectory ? 0 : 1
        self.dirCount = isDirectory ? 1 : 0
        self.children = []
        self.category = category
    }

    var displaySize: String { ByteFormatter.string(size) }

    /// Çocukları boyuta göre sıralı (büyükten küçüğe).
    func sortedChildren() -> [FileNode] {
        children.sorted { $0.size > $1.size }
    }
}
