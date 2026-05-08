import Foundation

struct VolumeInfo: Sendable {
    let path: String
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let importantUsage: Int64       // macOS bunu "kullanılan" olarak gösterir

    var usedCapacity: Int64 { totalCapacity - availableCapacity }

    static func boot() -> VolumeInfo {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        let values = (try? url.resourceValues(forKeys: keys))
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            path: "/",
            name: values?.volumeName ?? "Macintosh HD",
            totalCapacity: total,
            availableCapacity: available,
            importantUsage: total - available
        )
    }
}
