import SwiftUI

struct DuplicatesView: View {
    @Environment(ScanModel.self) private var model
    @State private var groups: [DuplicateGroup] = []
    @State private var phase: DuplicateFinder.Progress?
    @State private var minMB: Double = 50
    @State private var task: Task<Void, Never>?
    @State private var expanded: Set<UUID> = []
    @State private var lastError: String?
    @State private var cancelFlag = ManagedAtomicBool()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                controls
                if let p = phase { progressBanner(p) }
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicate Files")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 12) {
                StatPill(label: "Wasted Space",
                         value: ByteFormatter.string(totalWasted),
                         color: .orange,
                         icon: "exclamationmark.triangle.fill")
                StatPill(label: "Duplicate Groups",
                         value: "\(groups.count)",
                         color: .blue,
                         icon: "doc.on.doc.fill")
                StatPill(label: "Files",
                         value: "\(totalFiles)",
                         color: .indigo,
                         icon: "doc.fill")
            }
        }
    }

    private var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
    private var totalFiles: Int { groups.reduce(0) { $0 + $1.paths.count } }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Minimum size")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Slider(value: $minMB, in: 1...1024, step: 1).frame(width: 220)
                    Text("\(Int(minMB)) MB")
                        .font(.body.monospaced().weight(.medium))
                        .frame(width: 80, alignment: .leading)
                }
            }
            Spacer()
            if task == nil {
                Button { runScan() } label: {
                    Label("Find Duplicates", systemImage: "magnifyingglass")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.rootNode == nil)
            } else {
                Button(role: .destructive) {
                    cancelFlag.set(true)
                    task?.cancel(); task = nil; phase = nil
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - Progress banner

    private func progressBanner(_ p: DuplicateFinder.Progress) -> some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small).tint(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(p.phase))
                    .font(.callout.weight(.semibold))
                if p.total > 0 {
                    Text("\(p.done) / \(p.total)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                .tint(.orange)
                .frame(width: 220)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3)))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.rootNode == nil {
            EmptyState(icon: "doc.on.doc",
                       title: "Scan first",
                       message: "Run a scan from the toolbar so we have files to compare.")
        } else if groups.isEmpty && task == nil {
            EmptyState(icon: "checkmark.seal.fill",
                       title: "No duplicates yet",
                       message: "Press **Find Duplicates** above. Larger minimum sizes finish faster.")
        } else if !groups.isEmpty {
            VStack(spacing: 12) {
                ForEach(groups) { group in
                    DuplicateGroupCard(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        onToggle: { toggle(group.id) },
                        onTrash: { path in trash(path) },
                        onShow: { path in showInFinder(path) }
                    )
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: - Actions

    private func runScan() {
        guard let root = model.rootNode else { return }
        let min = Int64(minMB * 1024 * 1024)
        groups = []
        cancelFlag.set(false)
        let flag = cancelFlag
        phase = .init(phase: String(localized: "Starting"), done: 0, total: 0)
        task = Task {
            let result = await DuplicateFinder.find(
                in: root, minSize: min,
                progress: { p in Task { @MainActor in self.phase = p } },
                isCancelled: { flag.get() }
            )
            await MainActor.run {
                self.groups = result
                self.phase = nil
                self.task = nil
            }
        }
    }

    private func trash(_ path: String) {
        if let err = CleanupActions.moveToTrash(path) {
            lastError = err.localizedDescription
            return
        }
        for i in groups.indices {
            if let idx = groups[i].paths.firstIndex(of: path) {
                groups[i].paths.remove(at: idx)
                if groups[i].paths.count < 2 { groups.remove(at: i) }
                return
            }
        }
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Duplicate group card

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onTrash: (String) -> Void
    let onShow: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().opacity(0.5)
                fileRows
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: "doc.on.doc.fill").foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.paths.first.map { ($0 as NSString).lastPathComponent } ?? "")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text("\(group.paths.count) copies")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                        Text("\(ByteFormatter.string(group.size)) each")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormatter.string(group.wastedBytes))
                        .font(.title3.monospaced().weight(.bold))
                        .foregroundStyle(.green)
                    Text("recoverable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.tertiary)
                    .font(.caption.weight(.semibold))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fileRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(group.paths.enumerated()), id: \.offset) { idx, path in
                FileRow(path: path,
                        isOriginal: idx == 0,
                        onTrash: { onTrash(path) },
                        onShow: { onShow(path) })
                if idx < group.paths.count - 1 { Divider().opacity(0.3) }
            }
        }
    }
}

private struct FileRow: View {
    let path: String
    let isOriginal: Bool
    let onTrash: () -> Void
    let onShow: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isOriginal ? Color.yellow.opacity(0.18) : Color.gray.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: isOriginal ? "star.fill" : "doc.fill")
                    .foregroundStyle(isOriginal ? .yellow : .secondary)
                    .font(.caption)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isOriginal {
                Text("Original")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
            }
            HStack(spacing: 4) {
                Button(action: onShow) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                if !isOriginal {
                    Button(role: .destructive, action: onTrash) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .help("Move to Trash")
                }
            }
            .opacity(hovered ? 1 : 0.55)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - Reusable bits (used by other views too)

struct StatPill: View {
    let label: LocalizedStringKey
    let value: String
    let color: Color
    let icon: String
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: icon).foregroundStyle(color).font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.monospaced().weight(.bold))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.2)))
    }
}

struct EmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 50))
                .foregroundStyle(.tertiary)
            Text(title).font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
