import SwiftUI

struct CleanupView: View {
    @State private var results: [CleanupActions.Result] = []
    @State private var pending: Pending?
    @State private var sizes: [String: Int64] = [:]
    @State private var measuring: Set<String> = []
    @State private var trashSize: Int64 = 0
    @State private var snapshotsCount: Int = 0

    struct Pending: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        let action: @Sendable () async -> CleanupActions.Result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                developerSection
                systemSection
                otherSection
                if !results.isEmpty { historySection }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .alert(
            Text(pending?.title ?? "" as LocalizedStringResource),
            isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Continue", role: .destructive) { runPending() }
        } message: {
            if let p = pending { Text(p.detail) } else { Text("") }
        }
        .task { await measureAll() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cleanup")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                Button { Task { await measureAll(force: true) } } label: {
                    Label("Re-measure", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Text("Each card shows the **estimated size** of what it will delete. Every action still asks for confirmation.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatPill(label: "Reclaimable now",
                         value: ByteFormatter.string(reclaimable),
                         color: .green,
                         icon: "sparkles")
                StatPill(label: "Trash",
                         value: ByteFormatter.string(trashSize),
                         color: .red,
                         icon: "trash.fill")
                StatPill(label: "Snapshots",
                         value: "\(snapshotsCount)",
                         color: .indigo,
                         icon: "clock.arrow.circlepath")
            }
        }
    }

    private var reclaimable: Int64 {
        // Sum of all measurable cleanable directories.
        ["derived", "iosDevSupport", "userCaches", "logs", "archives"]
            .reduce(0) { $0 + (sizes[$1] ?? 0) } + trashSize
    }

    // MARK: - Sections

    private var developerSection: some View {
        SectionGroup(title: "Developer", icon: "hammer.fill", color: .yellow) {
            tile(id: "derived",
                 title: "Xcode DerivedData",
                 detail: "Build caches. Xcode regenerates them on next build.",
                 icon: "hammer.fill", color: .yellow,
                 path: derivedPath) {
                pendingDelete(at: derivedPath, title: "DerivedData")
            }
            tile(id: "iosDevSupport",
                 title: "iOS Device Support",
                 detail: "Symbols for old iOS versions you've connected.",
                 icon: "iphone.gen3", color: .blue,
                 path: iosDevSupportPath) {
                pendingDelete(at: iosDevSupportPath, title: "iOS Device Support")
            }
            tile(id: "simulators",
                 title: "Old Simulators",
                 detail: "Removes unavailable iOS simulator devices.",
                 icon: "iphone", color: .blue,
                 path: simulatorsPath,
                 customSize: nil) {
                pending = .init(title: "Delete Old Simulators",
                                detail: "Will run `xcrun simctl delete unavailable`.",
                                action: { await CleanupActions.deleteUnavailableSimulators() })
            }
            tile(id: "archives",
                 title: "Xcode Archives",
                 detail: "App Store distribution archives.",
                 icon: "shippingbox.fill", color: .yellow,
                 path: archivesPath) {
                pendingDelete(at: archivesPath, title: "Xcode Archives")
            }
        }
    }

    private var systemSection: some View {
        SectionGroup(title: "System", icon: "gearshape.fill", color: .indigo) {
            tile(id: "snapshots",
                 title: "APFS Snapshots",
                 detail: "Time Machine local snapshots.",
                 icon: "clock.arrow.circlepath", color: .indigo,
                 path: nil,
                 customSize: snapshotsCount > 0 ? "\(snapshotsCount)" : "—") {
                pending = .init(title: "Delete Snapshots",
                                detail: "Will run `tmutil deletelocalsnapshots /`. Safe if you have a Time Machine backup.",
                                action: { await CleanupActions.deleteLocalSnapshots() })
            }
            tile(id: "userCaches",
                 title: "User Caches",
                 detail: "Per-app caches under ~/Library/Caches.",
                 icon: "tray.full.fill", color: .gray,
                 path: cachesPath) {
                pendingDelete(at: cachesPath, title: "User Caches")
            }
            tile(id: "logs",
                 title: "App Logs",
                 detail: "Log files under ~/Library/Logs.",
                 icon: "doc.text", color: .secondary,
                 path: logsPath) {
                pendingDelete(at: logsPath, title: "Logs")
            }
        }
    }

    private var otherSection: some View {
        SectionGroup(title: "Other", icon: "ellipsis.circle.fill", color: .red) {
            tile(id: "trash",
                 title: "Empty Trash",
                 detail: "Permanently empties the Trash.",
                 icon: "trash.fill", color: .red,
                 path: nil,
                 customSize: ByteFormatter.string(trashSize)) {
                pending = .init(title: "Empty Trash",
                                detail: "The Trash will be emptied permanently. This cannot be undone.",
                                action: { await CleanupActions.emptyTrash() })
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.offset) { idx, r in
                    HStack(spacing: 12) {
                        Image(systemName: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.success ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).font(.callout.weight(.semibold))
                            Text(r.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.bytesFreed > 0 {
                            Text("Freed: \(ByteFormatter.string(r.bytesFreed))")
                                .font(.callout.monospaced().weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    if idx < results.count - 1 { Divider().opacity(0.3) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Tile builder

    @ViewBuilder
    private func tile(id: String,
                      title: LocalizedStringKey,
                      detail: LocalizedStringKey,
                      icon: String, color: Color,
                      path: String?,
                      customSize: String? = nil,
                      onTap: @escaping () -> Void) -> some View {
        let displaySize: String? = {
            if let custom = customSize { return custom }
            if measuring.contains(id) { return nil }
            if let bytes = sizes[id] { return ByteFormatter.string(bytes) }
            return "—"
        }()
        ActionTile(title: title, detail: detail, icon: icon, color: color,
                   sizeText: displaySize,
                   isMeasuring: measuring.contains(id),
                   path: path,
                   onTap: onTap)
    }

    private func pendingDelete(at path: String, title: LocalizedStringResource) {
        let est = ByteFormatter.string(sizes[idForPath(path)] ?? 0)
        pending = .init(title: "Clean \(String(localized: title))",
                        detail: "Contents of **\(path)** will be deleted.\nEstimated to free: **\(est)**",
                        action: { await CleanupActions.emptyDirectory(at: path, title: title) })
    }

    // MARK: - Paths + measurement

    private var derivedPath: String { NSString(string: "~/Library/Developer/Xcode/DerivedData").expandingTildeInPath }
    private var iosDevSupportPath: String { NSString(string: "~/Library/Developer/Xcode/iOS DeviceSupport").expandingTildeInPath }
    private var simulatorsPath: String { NSString(string: "~/Library/Developer/CoreSimulator").expandingTildeInPath }
    private var cachesPath: String { NSString(string: "~/Library/Caches").expandingTildeInPath }
    private var logsPath: String { NSString(string: "~/Library/Logs").expandingTildeInPath }
    private var archivesPath: String { NSString(string: "~/Library/Developer/Xcode/Archives").expandingTildeInPath }

    private func idForPath(_ path: String) -> String {
        switch path {
        case derivedPath: "derived"
        case iosDevSupportPath: "iosDevSupport"
        case simulatorsPath: "simulators"
        case cachesPath: "userCaches"
        case logsPath: "logs"
        case archivesPath: "archives"
        default: path
        }
    }

    private func measureAll(force: Bool = false) async {
        let work: [(String, String)] = [
            ("derived", derivedPath),
            ("iosDevSupport", iosDevSupportPath),
            ("simulators", simulatorsPath),
            ("userCaches", cachesPath),
            ("logs", logsPath),
            ("archives", archivesPath)
        ]
        if force { sizes = [:] }
        for (id, _) in work { measuring.insert(id) }
        snapshotsCount = APFSSnapshots.list().count

        await withTaskGroup(of: (String, Int64).self) { group in
            for (id, path) in work {
                group.addTask {
                    let bytes = SystemDataAnalyzer.directorySize(at: path)
                    return (id, bytes)
                }
            }
            group.addTask {
                let trashes = ["~/.Trash"].map { NSString(string: $0).expandingTildeInPath }
                let total = trashes.reduce(Int64(0)) { $0 + SystemDataAnalyzer.directorySize(at: $1) }
                return ("trash", total)
            }
            for await (id, bytes) in group {
                if id == "trash" { trashSize = bytes }
                else { sizes[id] = bytes }
                measuring.remove(id)
            }
        }
    }

    private func runPending() {
        guard let p = pending else { return }
        pending = nil
        Task {
            let r = await p.action()
            await MainActor.run {
                results.insert(r, at: 0)
            }
            await measureAll(force: true)
        }
    }
}

// MARK: - Section group container

private struct SectionGroup<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.headline)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                content()
            }
        }
    }
}

// MARK: - Action tile

struct ActionTile: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let icon: String
    let color: Color
    var sizeText: String? = nil
    var isMeasuring: Bool = false
    var path: String? = nil
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.18))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon).foregroundStyle(color).font(.title3)
                    }
                    Spacer()
                    if isMeasuring {
                        ProgressView().controlSize(.small)
                    } else if let s = sizeText {
                        Text(s)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .foregroundStyle(color)
                    }
                }
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let p = path {
                    Text(p).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(hovered ? color.opacity(0.10) : color.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(color.opacity(hovered ? 0.4 : 0.18), lineWidth: 1))
            .scaleEffect(hovered ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Status banner (used by SystemData & Cleanup)

struct StatusBanner: View {
    let text: String
    let color: Color
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.3)))
    }
}
