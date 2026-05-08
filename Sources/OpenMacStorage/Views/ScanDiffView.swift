import SwiftUI

struct ScanDiffView: View {
    @Environment(ScanModel.self) private var model
    @State private var entries: [ScanDiffEntry] = []
    @State private var loading = false
    @State private var hasPrevious = false
    @State private var oldDate: Date?
    @State private var filter: Filter = .all
    @State private var hoveredId: UUID?
    @State private var visibleCount: Int = 100

    enum Filter: String, CaseIterable, Identifiable {
        case all, grew, added, shrank, removed
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .all: "All"; case .grew: "Grew"; case .added: "Added"
            case .shrank: "Shrank"; case .removed: "Removed"
            }
        }
        var color: Color {
            switch self {
            case .all: .blue; case .grew: .red; case .added: .orange
            case .shrank: .green; case .removed: .mint
            }
        }
    }

    private var filteredEntries: [ScanDiffEntry] {
        switch filter {
        case .all: entries
        case .grew: entries.filter { $0.kind == .grew }
        case .added: entries.filter { $0.kind == .added }
        case .shrank: entries.filter { $0.kind == .shrank }
        case .removed: entries.filter { $0.kind == .removed }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if !entries.isEmpty {
                    filterBar
                    content
                } else if hasPrevious {
                    EmptyState(icon: "equal.circle",
                               title: "No significant changes",
                               message: "No deltas above 100 MB between the previous and current scan.")
                } else {
                    EmptyState(icon: "chart.line.uptrend.xyaxis",
                               title: "Two scans are needed",
                               message: "Run a scan now, then run another later — the difference between them will appear here.")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .task { await load() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("What Grew?")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            if let d = oldDate {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("Compared with previous scan from **\(d.formatted(date: .abbreviated, time: .shortened))**")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            HStack(spacing: 12) {
                StatPill(label: "Net Change",
                         value: signed(netDelta),
                         color: netDelta >= 0 ? .red : .green,
                         icon: netDelta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                StatPill(label: "Folders Grew",
                         value: "\(entries.filter { $0.kind == .grew }.count)",
                         color: .red,
                         icon: "arrow.up.right.circle.fill")
                StatPill(label: "Newly Added",
                         value: "\(entries.filter { $0.kind == .added }.count)",
                         color: .orange,
                         icon: "plus.circle.fill")
                StatPill(label: "Cleaned Up",
                         value: "\(entries.filter { $0.kind == .shrank || $0.kind == .removed }.count)",
                         color: .green,
                         icon: "minus.circle.fill")
            }
        }
    }

    private var netDelta: Int64 { entries.reduce(0) { $0 + $1.delta } }

    private func signed(_ bytes: Int64) -> String {
        let sign = bytes >= 0 ? "+" : "−"
        return "\(sign)\(ByteFormatter.string(abs(bytes)))"
    }

    // MARK: - Filter pills

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { f in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        filter = f
                        visibleCount = 100   // reset when filter changes
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(f.label).font(.callout.weight(.medium))
                        Text("\(countFor(f))")
                            .font(.caption.monospaced())
                            .foregroundStyle(filter == f ? .white.opacity(0.8) : .secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        Capsule().fill(filter == f ? f.color : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(filter == f ? Color.white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func countFor(_ f: Filter) -> Int {
        switch f {
        case .all: entries.count
        case .grew: entries.filter { $0.kind == .grew }.count
        case .added: entries.filter { $0.kind == .added }.count
        case .shrank: entries.filter { $0.kind == .shrank }.count
        case .removed: entries.filter { $0.kind == .removed }.count
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            EmptyState(icon: "line.horizontal.3.decrease.circle",
                       title: "No items in this filter",
                       message: "Try a different filter pill above.")
        } else {
            // LazyVStack only materialises rows as they scroll into view, which
            // matters when the diff has thousands of entries (otherwise SwiftUI
            // tries to build them all up front and the UI freezes).
            LazyVStack(spacing: 6) {
                ForEach(filteredEntries.prefix(visibleCount).map { $0 }) { e in
                    DiffRow(entry: e, hovered: hoveredId == e.id)
                        .onHover { hoveredId = $0 ? e.id : nil }
                }
                if filteredEntries.count > visibleCount {
                    Button {
                        withAnimation { visibleCount += 200 }
                    } label: {
                        Label("Load \(min(200, filteredEntries.count - visibleCount)) more (\(filteredEntries.count - visibleCount) hidden)",
                              systemImage: "ellipsis.circle.fill")
                            .padding(.vertical, 8).padding(.horizontal, 14)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        guard FileManager.default.fileExists(atPath: ScanArchive.previousURL.path) else {
            hasPrevious = false; return
        }
        hasPrevious = true
        guard let new = model.rootNode else { return }
        let oldResult: (root: FileNode, scanDate: Date)? = await Task.detached {
            try? ScanArchive.load(from: ScanArchive.previousURL)
        }.value
        guard let old = oldResult else { return }
        oldDate = old.scanDate
        entries = await Task.detached {
            ScanDiff.compare(old: old.root, new: new)
        }.value
    }
}

// MARK: - Diff row

private struct DiffRow: View {
    let entry: ScanDiffEntry
    let hovered: Bool

    private var directionIcon: String {
        switch entry.kind {
        case .grew:    "arrow.up.circle.fill"
        case .shrank:  "arrow.down.circle.fill"
        case .added:   "plus.circle.fill"
        case .removed: "minus.circle.fill"
        }
    }
    private var directionColor: Color {
        switch entry.kind {
        case .grew:    .red
        case .shrank:  .green
        case .added:   .orange
        case .removed: .mint
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(directionColor.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: directionIcon)
                    .foregroundStyle(directionColor)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout.weight(.semibold))
                Text(entry.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ByteFormatter.string(entry.oldSize))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(ByteFormatter.string(entry.newSize))
                        .font(.caption.monospaced())
                }
                Text("\(entry.delta > 0 ? "+" : (entry.delta < 0 ? "−" : ""))\(ByteFormatter.string(abs(entry.delta)))")
                    .font(.body.monospaced().weight(.bold))
                    .foregroundStyle(directionColor)
            }
            .frame(width: 220, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .opacity(hovered ? 1 : 0.4)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}
