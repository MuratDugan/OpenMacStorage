import SwiftUI
import Charts

struct FileTypeStatsView: View {
    @Environment(ScanModel.self) private var model
    @State private var stats: [TreeQueries.ExtStat] = []
    @State private var hoveredId: String?
    @State private var selectedExt: TreeQueries.ExtStat?

    private var totalBytes: Int64 { stats.reduce(0) { $0 + $1.totalBytes } }
    private var totalCount: Int   { stats.reduce(0) { $0 + $1.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if model.rootNode == nil {
                    EmptyState(icon: "doc.fill",
                               title: "Scan first",
                               message: "Run a scan from the toolbar so we can break down your files by type.")
                } else if stats.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }.task { compute() }
                } else {
                    chartCard
                    listCard
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .sheet(item: $selectedExt) { stat in
            if let root = model.rootNode {
                ExtensionFileListView(
                    ext: stat.ext,
                    displayExt: stat.displayExt,
                    tint: tint(for: stat.ext),
                    icon: icon(for: stat.ext),
                    root: root,
                    onClose: { selectedExt = nil }
                )
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Types")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Total disk usage by file extension. Useful for spotting one-off bloat — say a single 50 GB `.psd` you forgot about.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatPill(label: "Total Indexed",
                         value: ByteFormatter.string(totalBytes),
                         color: .blue,
                         icon: "scalemass")
                StatPill(label: "Distinct Types",
                         value: "\(stats.count)",
                         color: .indigo,
                         icon: "tag.fill")
                StatPill(label: "Files",
                         value: "\(totalCount)",
                         color: .teal,
                         icon: "doc.fill")
                if let top = stats.first {
                    StatPill(label: "Biggest Type",
                             value: top.displayExt,
                             color: tint(for: top.ext),
                             icon: icon(for: top.ext))
                }
            }
        }
    }

    // MARK: - Chart card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top 12 by size")
                .font(.headline)
            Chart(stats.prefix(12)) { s in
                BarMark(
                    x: .value("Size", s.totalBytes),
                    y: .value("Type", s.displayExt)
                )
                .foregroundStyle(tint(for: s.ext))
                .annotation(position: .trailing) {
                    Text(ByteFormatter.string(s.totalBytes))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .cornerRadius(3)
            }
            .frame(height: 360)
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - List card

    private var listCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All file types")
                    .font(.headline)
                Spacer()
                Text("\(stats.count) types")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider().opacity(0.4)
            ForEach(stats) { s in
                ExtRow(stat: s,
                       fraction: totalBytes > 0 ? Double(s.totalBytes) / Double(totalBytes) : 0,
                       hovered: hoveredId == s.id,
                       icon: icon(for: s.ext),
                       tint: tint(for: s.ext))
                    .onHover { hoveredId = $0 ? s.id : nil }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedExt = s }
                Divider().opacity(0.2)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Compute

    private func compute() {
        guard let root = model.rootNode else { return }
        Task.detached(priority: .userInitiated) {
            let result = TreeQueries.extensionStats(in: root, top: 80)
            await MainActor.run { self.stats = result }
        }
    }

    // MARK: - Per-extension icon + color

    private func icon(for ext: String) -> String {
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm":               "film.fill"
        case "mp3", "wav", "flac", "m4a", "aac", "ogg":        "music.note"
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp": "photo.fill"
        case "psd", "ai", "sketch", "fig":                     "paintbrush.fill"
        case "pdf":                                             "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz", "bz2":           "doc.zipper"
        case "dmg", "iso", "img", "raw":                        "opticaldisc.fill"
        case "nsp", "xci", "nca", "wbfs":                       "gamecontroller.fill"
        case "doc", "docx", "rtf", "pages":                     "doc.text.fill"
        case "xls", "xlsx", "csv", "numbers":                   "tablecells.fill"
        case "ppt", "pptx", "key":                              "rectangle.stack.fill"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h":
                                                                "chevron.left.forwardslash.chevron.right"
        case "html", "css":                                     "globe"
        case "json", "yaml", "yml", "toml", "xml":              "curlybraces"
        case "log", "txt", "md":                                "doc.plaintext.fill"
        case "app":                                              "app.fill"
        case "sqlite", "db":                                    "cylinder.fill"
        case "":                                                 "questionmark.circle"
        default:                                                 "doc.fill"
        }
    }

    private func tint(for ext: String) -> Color {
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm":               .purple
        case "mp3", "wav", "flac", "m4a", "aac", "ogg":        .pink
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp": .green
        case "psd", "ai", "sketch", "fig":                     .blue
        case "pdf":                                             .red
        case "zip", "rar", "7z", "tar", "gz", "bz2":           .yellow
        case "dmg", "iso", "img", "raw":                        .gray
        case "nsp", "xci", "nca", "wbfs":                       .red
        case "doc", "docx", "rtf", "pages":                     .blue
        case "xls", "xlsx", "csv", "numbers":                   .green
        case "ppt", "pptx", "key":                              .orange
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h":
                                                                .orange
        case "html", "css":                                     .cyan
        case "json", "yaml", "yml", "toml", "xml":              .teal
        case "log", "txt", "md":                                .secondary
        case "app":                                              .blue
        case "sqlite", "db":                                    .indigo
        default:                                                 .blue
        }
    }
}

// MARK: - Extension row

private struct ExtRow: View {
    let stat: TreeQueries.ExtStat
    let fraction: Double
    let hovered: Bool
    let icon: String
    let tint: Color

    private var avg: Int64 { stat.count > 0 ? stat.totalBytes / Int64(stat.count) : 0 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon).foregroundStyle(tint).font(.body)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.displayExt)
                        .font(.body.monospaced().weight(.semibold))
                    Text("\(stat.count) files · avg \(ByteFormatter.string(avg))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteFormatter.string(stat.totalBytes))
                        .font(.body.monospaced().weight(.bold))
                    Text(String(format: "%.1f%%", fraction * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption.weight(.semibold))
                    .opacity(hovered ? 1 : 0.5)
            }
            .padding(.horizontal, 16)
            // Share-of-total bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.85), tint.opacity(0.55)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, CGFloat(fraction) * geo.size.width))
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
    }
}
