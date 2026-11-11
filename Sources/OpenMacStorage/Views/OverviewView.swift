import SwiftUI

struct OverviewView: View {
    @Environment(ScanModel.self) private var model
    @State private var breakdown: StorageCategory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if model.isLegacyScan && model.rootNode != nil {
                    legacyBanner
                }
                if let root = model.rootNode {
                    diskCard(root: root)
                    statsRow(root: root)
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        categoriesCard(root: root)
                        insightsCard
                    }
                    topItemsCard(root: root)
                } else if case let .scanning(path, bytes, files, elapsed) = model.phase {
                    // No tree yet during the first scan — show live progress
                    // instead of the "No scan yet" call to action.
                    ScanProgressCard(path: path, bytes: bytes, files: files, elapsed: elapsed)
                } else {
                    emptyState
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $breakdown) { category in
            if let root = model.rootNode {
                CategoryBreakdownView(category: category, root: root,
                                      total: model.categoryTotals[category] ?? 0)
                    .environment(model)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Storage")
                    .font(.largeTitle.weight(.bold))
                statusLine
                    .font(.callout)
            }
            Spacer()
            if model.rootNode != nil, !isScanning {
                Button { model.startScan() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .help(Text("Scan \(model.currentRoot) again"))
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .idle:
            if let date = model.lastScanDate {
                Text("Last scan \(date.formatted(.relative(presentation: .named))) · \(model.currentRoot)")
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a folder in the toolbar and press Scan to begin.")
                    .foregroundStyle(.secondary)
            }
        case .scanning(_, let b, let f, _):
            HStack(spacing: Theme.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Scanning — \(f) files, \(ByteFormatter.string(b))")
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
        case .done(let t):
            Label("Scan complete in \(String(format: "%.1f", t)) s", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.positive)
        case .cancelled:
            Label("Scan cancelled — showing nothing until you scan again.", systemImage: "xmark.circle.fill")
                .foregroundStyle(Theme.caution)
        case .error(let m):
            Label("Error: \(m)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
        }
    }

    private var legacyBanner: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(Theme.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("These numbers come from an older scan").font(.headline)
                Text("It counted cloud-only files (iCloud, Nextcloud, Google Drive…) at full size, so totals are too high. Rescan for accurate on-disk sizes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Rescan Now") { model.startScan() }
                .buttonStyle(.borderedProminent)
        }
        .surfaceCard(padding: Theme.Space.m)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.caution.opacity(0.45)))
    }

    // MARK: - Disk bar

    private func diskCard(root: FileNode) -> some View {
        let vol = model.scanVolume
        let segments = diskSegments(root: root, volume: vol)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vol.name).font(.headline)
                    Text("\(ByteFormatter.string(vol.usedCapacity)) used of \(ByteFormatter.string(vol.totalCapacity))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormatter.string(vol.availableCapacity))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("available").font(.caption).foregroundStyle(.secondary)
                }
            }
            StorageBar(segments: segments, height: 26)
            Text("Sizes are space actually used on disk. Files that live only in the cloud are counted separately.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .surfaceCard()
    }

    private func diskSegments(root: FileNode, volume: VolumeInfo) -> [StorageBar.Segment] {
        let sorted = model.categoryTotals
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let shown = sorted.prefix(7)
        let rest = sorted.dropFirst(7).reduce(Int64(0)) { $0 + $1.value }

        var segs: [StorageBar.Segment] = shown.map {
            .init(id: $0.key.rawValue, label: String(localized: $0.key.localizedName),
                  bytes: $0.value, color: $0.key.color)
        }
        if rest > 0 {
            segs.append(.init(id: "rest", label: String(localized: "Other categories"),
                              bytes: rest, color: StorageCategory.other.color.opacity(0.6)))
        }
        // Only meaningful when the scan and the volume line up.
        if volume.path == root.path || root.path.hasPrefix(volume.path == "/" ? "/" : volume.path + "/") {
            let outside = volume.usedCapacity - root.size
            if outside > 0 {
                segs.append(.init(id: "outside", label: String(localized: "Not in this scan"),
                                  bytes: outside, color: Theme.outside, hatched: true))
            }
            segs.append(.init(id: "free", label: String(localized: "Free"),
                              bytes: volume.availableCapacity, color: Theme.free))
        }
        return segs
    }

    // MARK: - Stats

    private func statsRow(root: FileNode) -> some View {
        let reclaimable = model.insights.filter(\.reclaimable).reduce(Int64(0)) { $0 + $1.bytes }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.m)],
                         spacing: Theme.Space.m) {
            StatPill(label: "Scanned, on disk", value: ByteFormatter.string(root.size),
                     color: .accentColor, icon: "internaldrive.fill")
            StatPill(label: "Files · folders",
                     value: "\(root.fileCount.formatted()) · \(root.dirCount.formatted())",
                     color: .indigo, icon: "doc.on.doc.fill")
            StatPill(label: "Only in the cloud", value: ByteFormatter.string(root.cloudSize),
                     color: Theme.cloud, icon: "icloud.fill",
                     footnote: "Not using local space")
            StatPill(label: "Easy to reclaim", value: ByteFormatter.string(reclaimable),
                     color: Theme.reclaim, icon: "sparkles",
                     footnote: "Trash, caches, logs, build folders")
        }
    }

    // MARK: - Categories

    private func categoriesCard(root: FileNode) -> some View {
        let items = model.categoryTotals
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let total = max(1, root.size)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Categories", subtitle: "Click one to see where the space is")
            if items.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(items, id: \.key) { item in
                        CategoryRow(category: item.key, bytes: item.value,
                                    fraction: Double(item.value) / Double(total)) {
                            breakdown = item.key
                        }
                    }
                }
            }
        }
        .surfaceCard()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Insights

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Suggestions", subtitle: "Where space can be recovered")
            if model.insights.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.positive)
                    Text("Nothing big to clean up here.").foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Space.xs)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.insights) { insight in
                        InsightRow(insight: insight) {
                            if insight.opensCleanup {
                                NotificationCenter.default.post(name: .showCleanup, object: nil)
                            } else if let t = insight.target {
                                model.browseTarget = t
                            }
                        }
                    }
                }
            }
        }
        .surfaceCard()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Top items

    private func topItemsCard(root: FileNode) -> some View {
        let top = root.sortedChildren().prefix(12)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Largest items", subtitle: "Inside \(root.name)")
            VStack(spacing: 2) {
                ForEach(Array(top), id: \.id) { node in
                    TopRow(node: node, total: max(1, root.size)) {
                        model.browseTarget = node
                    }
                }
            }
        }
        .surfaceCard()
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyState(icon: "internaldrive",
                       title: "No scan yet",
                       message: "Pick a location in the toolbar — your Home folder is a good start. Grant Full Disk Access first, otherwise parts of ~/Library stay hidden.")
            Button { model.startScan() } label: {
                Label("Scan Now", systemImage: "play.fill")
                    .padding(.horizontal, Theme.Space.xs)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
    }
}

// MARK: - Rows

/// Shared hover-highlighted row container (whole row is the click target).
private struct HoverRow<Content: View>: View {
    let action: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { row(highlight: hovering) }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Theme.Motion.quick) { hovering = h } }
        } else {
            // Not clickable: same look, no hover, never dimmed.
            row(highlight: false)
        }
    }

    private func row(highlight: Bool) -> some View {
        content()
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(highlight ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
    }
}

private struct CategoryRow: View {
    let category: StorageCategory
    let bytes: Int64
    let fraction: Double
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: category.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(category.color)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(category.color.opacity(0.16)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(category.localizedName).lineLimit(1)
                        Spacer()
                        Text(ByteFormatter.string(bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ShareBar(fraction: fraction, color: category.color, height: 4)
                }
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

private struct InsightRow: View {
    let insight: Insight
    let action: () -> Void

    var body: some View {
        HoverRow(action: insight.target == nil && !insight.opensCleanup ? nil : action) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: insight.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(insight.color)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(insight.color.opacity(0.16)))
                VStack(alignment: .leading, spacing: 3) {
                    FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xxs) {
                        Text(insight.title).font(.body.weight(.medium))
                        if insight.reclaimable {
                            TagBadge(text: "Reclaimable", icon: "sparkles", color: Theme.reclaim)
                        }
                        if insight.kind == .cloud {
                            TagBadge(text: "No local space", icon: "icloud", color: Theme.cloud)
                        }
                    }
                    Text(insight.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.xs)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ByteFormatter.string(insight.bytes))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    if insight.opensCleanup {
                        Text("Cleanup")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if insight.target != nil {
                        Text("Show")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}

struct TopRow: View {
    let node: FileNode
    let total: Int64
    var action: (() -> Void)? = nil

    var body: some View {
        let frac = total > 0 ? Double(node.size) / Double(total) : 0
        let info = FileIconInfo.forNode(node)
        HoverRow(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: info.symbol)
                    .font(.system(size: 12, weight: node.isDirectory ? .semibold : .regular))
                    .foregroundStyle(info.color)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(info.color.opacity(0.16)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                        if node.cloudSize >= 100 * 1024 * 1024 {
                            TagBadge(text: "+\(ByteFormatter.string(node.cloudSize)) in cloud",
                                     icon: "icloud", color: Theme.cloud)
                        }
                        Spacer()
                        Text(ByteFormatter.string(node.size))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ShareBar(fraction: frac, color: node.category.color, height: 4)
                }
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            }
        }
    }
}

// MARK: - Scan progress

struct ScanProgressCard: View {
    let path: String
    let bytes: Int64
    let files: Int
    let elapsed: Double
    @Environment(ScanModel.self) private var model

    var body: some View {
        // Files/sec is the clearest "is it moving?" signal.
        let rate = elapsed > 0.5 ? Double(files) / elapsed : 0
        VStack(spacing: Theme.Space.l) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: Theme.Space.xxs) {
                Text("Scanning…").font(.title2.weight(.semibold))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 560)
            }
            Grid(horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.xxs) {
                GridRow {
                    metric(files.formatted())
                    metric(ByteFormatter.string(bytes))
                    metric(Self.formatElapsed(elapsed))
                    metric(rate > 0 ? Int(rate).formatted() : "—")
                }
                GridRow {
                    caption("files")
                    caption("on disk")
                    caption("elapsed")
                    caption("files / s")
                }
            }
            Text("The window stays responsive — feel free to look around while it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { model.cancel() } label: {
                Label("Stop Scan", systemImage: "stop.fill")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .surfaceCard()
    }

    private func metric(_ s: String) -> some View {
        Text(s).font(.title3.weight(.semibold)).monospacedDigit()
    }
    private func caption(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }
}
