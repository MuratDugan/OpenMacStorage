import SwiftUI

struct OldFilesView: View {
    @State private var entries: [TreeQueries.OldFileEntry] = []
    @State private var loading = false
    @State private var days: Double = 90
    @State private var minMB: Double = 50
    @State private var includeIcloud = true
    @State private var lastError: String?
    @State private var hoveredId: UUID?

    private let presets: [(LocalizedStringKey, Int)] = [
        ("30 days", 30),
        ("90 days", 90),
        ("6 months", 180),
        ("1 year", 365),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                controls
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .task { await reload() }
        .alert("Error", isPresented: .init(get: { lastError != nil },
                                           set: { if !$0 { lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(lastError ?? "")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Old Downloads")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Large files in your **Downloads** that haven't been touched in a while. Often the easiest source of GBs.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatPill(label: "Reclaimable",
                         value: ByteFormatter.string(entries.reduce(0) { $0 + $1.size }),
                         color: .green,
                         icon: "arrow.down.circle.fill")
                StatPill(label: "Files",
                         value: "\(entries.count)",
                         color: .blue,
                         icon: "doc.fill")
                StatPill(label: "Older Than",
                         value: "\(Int(days)) d",
                         color: .indigo,
                         icon: "calendar.badge.clock")
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Quick presets:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(presets, id: \.1) { name, value in
                    Button {
                        days = Double(value)
                        Task { await reload() }
                    } label: {
                        Text(name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    Int(days) == value
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.06)
                                )
                            )
                            .foregroundStyle(Int(days) == value ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Toggle("Include iCloud Drive", isOn: $includeIcloud)
                    .controlSize(.small)
                    .onChange(of: includeIcloud) { _, _ in Task { await reload() } }
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Older than: **\(Int(days)) days**").font(.caption)
                    Slider(value: $days, in: 7...365, step: 1) { editing in
                        if !editing { Task { await reload() } }
                    }
                    .frame(width: 240)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Min size: **\(Int(minMB)) MB**").font(.caption)
                    Slider(value: $minMB, in: 5...1024, step: 1) { editing in
                        if !editing { Task { await reload() } }
                    }
                    .frame(width: 240)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty && !loading {
            EmptyState(icon: "checkmark.seal",
                       title: "No old large files",
                       message: "Your Downloads folder is tidy. Try lowering the size threshold to see smaller files.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Name").font(.caption.weight(.semibold))
                    Spacer()
                    Text("Size").font(.caption.weight(.semibold))
                        .frame(width: 90, alignment: .trailing)
                    Text("Modified").font(.caption.weight(.semibold))
                        .frame(width: 120, alignment: .trailing)
                    Color.clear.frame(width: 70)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.primary.opacity(0.04))
                Divider().opacity(0.4)
                ForEach(entries) { entry in
                    OldFileRow(entry: entry,
                               hovered: hoveredId == entry.id,
                               onShow: { showInFinder(entry.path) },
                               onTrash: { trash(entry) })
                        .onHover { hoveredId = $0 ? entry.id : nil }
                    Divider().opacity(0.2)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Helpers

    private func reload() async {
        loading = true
        let home = NSString(string: "~").expandingTildeInPath
        var roots = ["\(home)/Downloads"]
        if includeIcloud {
            roots.append("\(home)/Library/Mobile Documents/com~apple~CloudDocs/Downloads")
            roots.append("\(home)/Library/Mobile Documents/com~apple~CloudDocs")
        }
        let result = await TreeQueries.oldFiles(in: roots,
                                                olderThanDays: Int(days),
                                                minSize: Int64(minMB * 1024 * 1024))
        entries = result
        loading = false
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func trash(_ e: TreeQueries.OldFileEntry) {
        if let err = CleanupActions.moveToTrash(e.path) {
            lastError = err.localizedDescription
            return
        }
        entries.removeAll { $0.id == e.id }
    }
}

// MARK: - Row

private struct OldFileRow: View {
    let entry: TreeQueries.OldFileEntry
    let hovered: Bool
    let onShow: () -> Void
    let onTrash: () -> Void

    private var ageDays: Int {
        max(0, Int(Date().timeIntervalSince(entry.modified) / 86400))
    }

    private var fileTypeIcon: String {
        let ext = (entry.path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm":              return "film.fill"
        case "mp3", "wav", "flac", "m4a", "aac":              return "music.note"
        case "jpg", "jpeg", "png", "heic", "gif", "tiff":     return "photo.fill"
        case "pdf":                                            return "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz":                  return "doc.zipper"
        case "dmg", "iso", "img", "raw":                       return "opticaldisc.fill"
        case "nsp", "xci", "nca":                              return "gamecontroller.fill"
        case "doc", "docx":                                    return "doc.text.fill"
        case "xls", "xlsx", "csv":                             return "tablecells.fill"
        case "ppt", "pptx":                                    return "rectangle.stack.fill"
        default:                                                return "doc.fill"
        }
    }

    private var iconTint: Color {
        let ext = (entry.path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm":              return .purple
        case "mp3", "wav", "flac", "m4a", "aac":              return .pink
        case "jpg", "jpeg", "png", "heic", "gif", "tiff":     return .green
        case "pdf":                                            return .red
        case "zip", "rar", "7z", "tar", "gz":                  return .yellow
        case "dmg", "iso", "img", "raw":                       return .gray
        case "nsp", "xci", "nca":                              return .red
        default:                                                return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(iconTint.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: fileTypeIcon)
                    .foregroundStyle(iconTint)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text((entry.path as NSString).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text((entry.path as NSString).deletingLastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormatter.string(entry.size))
                .font(.body.monospaced().weight(.medium))
                .frame(width: 90, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.monospaced())
                Text("\(ageDays) days ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .trailing)
            HStack(spacing: 2) {
                Button(action: onShow) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                Button(role: .destructive, action: onTrash) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .tint(.red)
                .help("Move to Trash")
            }
            .frame(width: 70)
            .opacity(hovered ? 1.0 : 0.55)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
    }
}
