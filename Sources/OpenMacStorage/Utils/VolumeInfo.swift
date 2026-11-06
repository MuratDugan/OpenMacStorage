import Foundation

struct VolumeInfo: Sendable {
    let path: String
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let importantUsage: Int64       // macOS bunu "kullanılan" olarak gösterir

    var usedCapacity: Int64 { totalCapacity - availableCapacity }

    static func boot() -> VolumeInfo { forPath("/") }

    /// The volume containing `path`.
    static func forPath(_ path: String) -> VolumeInfo {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeURLKey
        ]
        let values = (try? url.resourceValues(forKeys: keys))
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            path: values?.volume?.path ?? "/",
            name: values?.volumeName ?? "Macintosh HD",
            totalCapacity: total,
            availableCapacity: available,
            importantUsage: total - available
        )
    }
}
