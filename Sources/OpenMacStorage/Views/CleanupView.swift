import SwiftUI

struct CleanupView: View {
    @State private var results: [CleanupActions.Result] = []
    @State private var pending: Pending?
    @State private var sizes: [String: Int64] = [:]
    @State private var measuring: Set<String> = []
    @State private var running: Set<String> = []
    @State private var snapshotsCount: Int = 0
    /// Dev tools found on this Mac (binary located), with their binary path.
    @State private var installedTools: [DevTool] = []

    struct Pending: Identifiable {
        let id = UUID()
        let key: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        var destructive = true
        let action: @Sendable () async -> CleanupActions.Result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                statsRow
                if !installedTools.isEmpty { devToolsSection }
                xcodeSection
                systemSection
                if !results.isEmpty { historySection }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .alert(
            Text(pending?.title ?? "" as LocalizedStringResource),
            isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Continue", role: pending?.destructive == true ? .destructive : nil) { runPending() }
        } message: {
            if let p = pending { Text(p.detail) } else { Text("") }
        }
        .task { await measureAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Cleanup").font(.largeTitle.weight(.bold))
                Text("Sizes are measured live. Nothing runs until you confirm, and each row shows exactly what it will do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await measureAll(force: true) } } label: {
                Label("Re-measure", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .disabled(!measuring.isEmpty)
        }
    }

    private var statsRow: some View {
        let devTotal = installedTools.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.m)],
                         spacing: Theme.Space.m) {
            StatPill(label: "Reclaimable now", value: ByteFormatter.string(reclaimable),
                     color: Theme.reclaim, icon: "sparkles")
            StatPill(label: "Developer tool caches", value: ByteFormatter.string(devTotal),
                     color: StorageCategory.developerXcode.color, icon: "hammer.fill",
                     footnote: "\(installedTools.count) tools found")
            StatPill(label: "Trash", value: ByteFormatter.string(sizes["trash"] ?? 0),
                     color: StorageCategory.trash.color, icon: "trash.fill")
            StatPill(label: "Local snapshots", value: "\(snapshotsCount)",
                     color: StorageCategory.snapshots.color, icon: "clock.arrow.circlepath")
        }
    }

    private var reclaimable: Int64 {
        let fixed = ["derived", "iosDevSupport", "userCaches", "logs", "archives", "trash"]
        return fixed.reduce(0) { $0 + (sizes[$1] ?? 0) }
            + installedTools.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    // MARK: - Sections

    private var devToolsSection: some View {
        CleanupSection(title: "Developer tools",
                       subtitle: "Runs each tool's own cleanup command — only data it can download again is removed.") {
            ForEach(installedTools) { tool in
                CleanupRow(
                    title: LocalizedStringKey(tool.name),
                    detail: LocalizedStringKey(String(localized: tool.detail)),
                    icon: tool.symbol, color: tool.color,
                    command: DevToolCleanup.commandLine(tool),
                    sizeText: sizeText(tool.id, prefix: tool.sizeIsUpperBound ? "≤ " : ""),
                    isMeasuring: measuring.contains(tool.id),
                    isRunning: running.contains(tool.id),
                    actionTitle: "Run"
                ) {
                    pending = .init(key: tool.id,
                                    title: "Clean \(tool.name)?",
                                    detail: "Will run `\(DevToolCleanup.commandLine(tool))`. Installed packages and your projects are not touched.",
                                    destructive: false,
                                    action: { await DevToolCleanup.run(tool) })
                }
            }
        }
    }

    private var xcodeSection: some View {
        CleanupSection(title: "Xcode",
                       subtitle: "Regenerated by Xcode when needed.") {
            dirRow(id: "derived", title: "DerivedData",
                   detail: "Build products and indexes. Rebuilt on the next build.",
                   icon: "hammer.fill", color: .yellow, path: derivedPath)
            dirRow(id: "iosDevSupport", title: "iOS Device Support",
                   detail: "Debug symbols for iOS versions you've connected. Re-copied when a device connects.",
                   icon: "iphone.gen3", color: .blue, path: iosDevSupportPath)
            CleanupRow(title: "Unavailable simulators",
                       detail: "Simulator devices for runtimes that are no longer installed.",
                       icon: "iphone", color: .blue,
                       command: "xcrun simctl delete unavailable",
                       sizeText: nil, isMeasuring: false,
                       isRunning: running.contains("simulators"),
                       actionTitle: "Run") {
                pending = .init(key: "simulators", title: "Delete unavailable simulators?",
                                detail: "Will run `xcrun simctl delete unavailable`.",
                                destructive: false,
                                action: { await CleanupActions.deleteUnavailableSimulators() })
            }
            dirRow(id: "archives", title: "Archives",
                   detail: "App Store builds. Keep the ones you may need to symbolicate crashes.",
                   icon: "archivebox.fill", color: .yellow, path: archivesPath)
        }
    }

    private var systemSection: some View {
        CleanupSection(title: "System", subtitle: "Caches, logs, snapshots and the Trash.") {
            dirRow(id: "userCaches", title: "User caches",
                   detail: "Everything under ~/Library/Caches. Apps rebuild it; quit them first for best results.",
                   icon: "tray.full.fill", color: StorageCategory.caches.color, path: cachesPath)
            dirRow(id: "logs", title: "App logs",
                   detail: "Log files under ~/Library/Logs.",
                   icon: "doc.text.magnifyingglass", color: StorageCategory.logs.color, path: logsPath)
            CleanupRow(title: "Local Time Machine snapshots",
                       detail: "Snapshots macOS keeps on this disk. Safe when you have a real backup.",
                       icon: "clock.arrow.circlepath", color: StorageCategory.snapshots.color,
                       command: "tmutil deletelocalsnapshots /",
                       sizeText: snapshotsCount > 0 ? "\(snapshotsCount)" : "—",
                       isMeasuring: false, isRunning: running.contains("snapshots"),
                       actionTitle: "Delete…") {
                pending = .init(key: "snapshots", title: "Delete snapshots?",
                                detail: "Will run `tmutil deletelocalsnapshots /`. Safe if you have a Time Machine backup.",
                                action: { await CleanupActions.deleteLocalSnapshots() })
            }
            CleanupRow(title: "Empty Trash",
                       detail: "Permanently deletes what's in the Trash. This cannot be undone.",
                       icon: "trash.fill", color: StorageCategory.trash.color,
                       command: nil,
                       sizeText: sizeText("trash"),
                       isMeasuring: measuring.contains("trash"),
                       isRunning: running.contains("trash"),
                       actionTitle: "Empty…") {
                pending = .init(key: "trash", title: "Empty Trash?",
                                detail: "The Trash will be emptied permanently. This cannot be undone.",
                                action: { await CleanupActions.emptyTrash() })
            }
        }
    }

    private var historySection: some View {
        CleanupSection(title: "History", subtitle: nil) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.success ? Theme.positive : Theme.caution)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.callout.weight(.semibold))
                        Text(r.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if r.bytesFreed > 0 {
                        Text("Freed \(ByteFormatter.string(r.bytesFreed))")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.positive)
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
            }
        }
    }

    // MARK: - Builders

    private func sizeText(_ id: String, prefix: String = "") -> String? {
        if measuring.contains(id) { return nil }
        guard let b = sizes[id] else { return "—" }
        return prefix + ByteFormatter.string(b)
    }

    private func dirRow(id: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                        icon: String, color: Color, path: String) -> some View {
        CleanupRow(title: title, detail: detail, icon: icon, color: color,
                   command: (path as NSString).abbreviatingWithTildeInPath,
                   commandIsPath: true,
                   sizeText: sizeText(id),
                   isMeasuring: measuring.contains(id),
                   isRunning: running.contains(id),
                   actionTitle: "Clean…") {
            let est = ByteFormatter.string(sizes[id] ?? 0)
            let name = (path as NSString).lastPathComponent
            pending = .init(key: id, title: "Clean \(name)?",
                            detail: "The contents of \((path as NSString).abbreviatingWithTildeInPath) will be deleted permanently (the folder itself stays). Estimated: \(est).",
                            action: { await CleanupActions.emptyDirectory(at: path, title: "\(name)") })
        }
    }

    // MARK: - Paths + measurement

    private var derivedPath: String { NSString(string: "~/Library/Developer/Xcode/DerivedData").expandingTildeInPath }
    private var iosDevSupportPath: String { NSString(string: "~/Library/Developer/Xcode/iOS DeviceSupport").expandingTildeInPath }
    private var cachesPath: String { NSString(string: "~/Library/Caches").expandingTildeInPath }
    private var logsPath: String { NSString(string: "~/Library/Logs").expandingTildeInPath }
    private var archivesPath: String { NSString(string: "~/Library/Developer/Xcode/Archives").expandingTildeInPath }
    private var trashPath: String { NSString(string: "~/.Trash").expandingTildeInPath }

    private func measureAll(force: Bool = false) async {
        let tools = await Task.detached { DevTool.all.filter { DevToolCleanup.locate($0) != nil } }.value
        installedTools = tools

        var work: [(String, @Sendable () -> Int64)] = [
            ("derived", { [derivedPath] in SystemDataAnalyzer.directorySize(at: derivedPath) }),
            ("iosDevSupport", { [iosDevSupportPath] in SystemDataAnalyzer.directorySize(at: iosDevSupportPath) }),
            ("userCaches", { [cachesPath] in SystemDataAnalyzer.directorySize(at: cachesPath) }),
            ("logs", { [logsPath] in SystemDataAnalyzer.directorySize(at: logsPath) }),
            ("archives", { [archivesPath] in SystemDataAnalyzer.directorySize(at: archivesPath) }),
            ("trash", { [trashPath] in SystemDataAnalyzer.directorySize(at: trashPath) }),
        ]
        for tool in tools where !tool.cachePaths.isEmpty {
            work.append((tool.id, { DevToolCleanup.measure(tool) }))
        }
        if force { sizes = [:] }
        for (id, _) in work { measuring.insert(id) }
        snapshotsCount = await Task.detached { APFSSnapshots.list().count }.value

        await withTaskGroup(of: (String, Int64).self) { group in
            for (id, job) in work {
                group.addTask { (id, job()) }
            }
            for await (id, bytes) in group {
                sizes[id] = bytes
                measuring.remove(id)
            }
        }
    }

    private func runPending() {
        guard let p = pending else { return }
        pending = nil
        running.insert(p.key)
        Task {
            let r = await p.action()
            results.insert(r, at: 0)
            running.remove(p.key)
            await measureAll(force: true)
        }
    }
}

// MARK: - Section + row

private struct CleanupSection<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title, subtitle: subtitle)
            VStack(spacing: 0) {
                content()
            }
        }
        .surfaceCard()
    }
}

private struct CleanupRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let icon: String
    let color: Color
    /// Shell command (or path) shown in monospace so the user sees exactly
    /// what will happen.
    let command: String?
    var commandIsPath = false
    let sizeText: String?
    let isMeasuring: Bool
    let isRunning: Bool
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command {
                    HStack(spacing: 4) {
                        Image(systemName: commandIsPath ? "folder" : "terminal")
                        Text(verbatim: command).textSelection(.enabled)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Space.m)
            Group {
                if isMeasuring {
                    ProgressView().controlSize(.small)
                } else if let sizeText {
                    Text(sizeText)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
            Group {
                if isRunning {
                    ProgressView().controlSize(.small).frame(width: 84)
                } else {
                    Button(actionTitle, action: action)
                        .frame(width: 84)
                }
            }
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.xs)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

// MARK: - Status banner (used by SystemData & App Uninstaller)

struct StatusBanner: View {
    let text: String
    let color: Color
    let icon: String
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(.primary)
            Spacer()
        }
        .padding(Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(color.opacity(0.3)))
    }
}
