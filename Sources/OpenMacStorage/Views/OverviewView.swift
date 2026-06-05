import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.rootNode == nil {
                    // While the first scan is running we don't have a tree yet —
                    // show a busy panel instead of the "No scan yet" CTA so the
                    // user doesn't think we're idle while taking 5+ minutes.
                    if case let .scanning(path, bytes, files, elapsed) = model.phase {
                        scanningState(path: path, bytes: bytes, files: files, elapsed: elapsed)
                    } else {
                        emptyState
                    }
                } else {
                    summaryCards
                    categoryChart
                    topItems
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scanningState(path: String, bytes: Int64, files: Int, elapsed: Double) -> some View {
        // Files/sec is the easiest "is it actually moving?" signal — if this
        // stays at 0 for a while you really are stuck.
        let rate = elapsed > 0.5 ? Double(files) / elapsed : 0
        return VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.4)
                .padding(.bottom, 4)
            Text("Scanning…").font(.title2.bold())
            HStack(spacing: 20) {
                stat(symbol: "doc.fill", value: "\(files) files")
                stat(symbol: "scalemass", value: ByteFormatter.string(bytes))
            }
            HStack(spacing: 20) {
                stat(symbol: "clock", value: Self.formatElapsed(elapsed))
                stat(symbol: "speedometer",
                     value: rate > 0 ? "\(Int(rate)) files/s" : "—")
            }
            .foregroundStyle(.tertiary)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 620)
            Text("Big disks can take a few minutes. The window stays responsive — feel free to switch tabs while it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.top, 4)
            Button(role: .destructive) { model.cancel() } label: {
                Label("Stop Scan", systemImage: "stop.circle.fill")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func stat(symbol: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced().weight(.medium))
        }
    }

    static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .idle:
            if let date = model.lastScanDate {
                Text("Last scan: **\(date.formatted(date: .abbreviated, time: .shortened))** — press **Scan** to refresh.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a folder and press **Scan** to begin.").foregroundStyle(.secondary)
            }
        case .scanning(let p, let b, let f, _):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning — \(f) files, \(ByteFormatter.string(b))")
                Spacer()
                Text(p).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
        case .done(let t):
            Text("Scan complete — \(String(format: "%.1f", t)) s").foregroundStyle(.green)
        case .cancelled:
            Text("Cancelled.").foregroundStyle(.orange)
        case .error(let m):
            Text("Error: \(m)").foregroundStyle(.red)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("No scan yet").font(.title2.bold())
            Text("To scan the whole disk, choose a root from the toolbar. On first run, grant Full Disk Access in System Settings — otherwise some folders inside `~/Library` will appear empty.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Scan Now") { model.startScan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var summaryCards: some View {
        let total = model.rootNode?.size ?? 0
        let files = model.rootNode?.fileCount ?? 0
        let dirs = model.rootNode?.dirCount ?? 0
        return HStack(spacing: 16) {
            Card(title: "Total", value: ByteFormatter.string(total), color: .blue, symbol: "scalemass")
            Card(title: "Files", value: "\(files)", color: .indigo, symbol: "doc.fill")
            Card(title: "Folders", value: "\(dirs)", color: .teal, symbol: "folder.fill")
            Card(title: "Free", value: ByteFormatter.string(model.volume.availableCapacity), color: .green, symbol: "checkmark.seal.fill")
        }
    }

    private var categoryChart: some View {
        let items = model.categoryTotals
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }

        return VStack(alignment: .leading, spacing: 8) {
            Text("By Category").font(.title3.bold())
            if items.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                Chart(items, id: \.key) { item in
                    BarMark(
                        x: .value("Size", item.value),
                        y: .value("Category", String(localized: item.key.localizedName))
                    )
                    .foregroundStyle(item.key.color)
                    .annotation(position: .trailing) {
                        Text(ByteFormatter.string(item.value))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: CGFloat(items.count) * 28 + 20)
                .chartXAxis(.hidden)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
    }

    private var topItems: some View {
        let top = (model.rootNode?.children ?? [])
            .sorted { $0.size > $1.size }
            .prefix(15)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top 15 Items").font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(Array(top), id: \.id) { node in
                    TopRow(node: node, total: model.rootNode?.size ?? 1)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        }
    }
}

struct Card: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

struct TopRow: View {
    let node: FileNode
    let total: Int64
    var body: some View {
        let frac = total > 0 ? Double(node.size) / Double(total) : 0
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.category.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2).fill(node.category.color.opacity(0.7))
                            .frame(width: max(2, CGFloat(frac) * geo.size.width))
                    }
                }.frame(height: 4)
            }
            Spacer()
            Text(ByteFormatter.string(node.size))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
