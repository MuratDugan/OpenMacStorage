import SwiftUI

struct SystemDataView: View {
    @Environment(ScanModel.self) private var model
    @State private var pendingClean: PendingClean?
    @State private var lastResult: CleanupActions.Result?

    struct PendingClean: Identifiable {
        let id = UUID()
        let bucket: SystemDataReport.Bucket
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if let r = model.systemReport {
                    summaryCards(report: r)
                    bucketList(report: r)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Analyzing…").foregroundStyle(.secondary)
                    }
                    .task { model.runSystemAnalysis() }
                }
                if let r = lastResult {
                    StatusBanner(text: String(localized: r.message),
                                 color: r.success ? .green : .orange,
                                 icon: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.systemReport = nil
                    model.runSystemAnalysis()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .alert(item: $pendingClean) { p in
            Alert(
                title: Text("Empty \(String(localized: p.bucket.title))?"),
                message: Text(p.bucket.detail),
                primaryButton: .destructive(Text("Empty Contents")) {
                    cleanBucket(p.bucket)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where Did System Data Go?")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Components that macOS rolls into its opaque \"System Data\" bucket. Most are safe to clean.")
                .foregroundStyle(.secondary)
        }
    }

    private func summaryCards(report r: SystemDataReport) -> some View {
        let cleanableBytes = r.buckets.filter(\.cleanable).reduce(0) { $0 + $1.bytes }
        return HStack(spacing: 12) {
            StatPill(label: "Computed Total",
                     value: ByteFormatter.string(r.totalBytes),
                     color: .blue,
                     icon: "scalemass")
            StatPill(label: "Components",
                     value: "\(r.buckets.count)",
                     color: .indigo,
                     icon: "list.bullet.rectangle")
            StatPill(label: "Cleanable",
                     value: ByteFormatter.string(cleanableBytes),
                     color: .green,
                     icon: "sparkles")
        }
    }

    private func bucketList(report r: SystemDataReport) -> some View {
        VStack(spacing: 10) {
            ForEach(r.buckets) { bucket in
                BucketCard(bucket: bucket,
                           totalBytes: r.totalBytes,
                           onClean: {
                               if bucket.cleanable { pendingClean = PendingClean(bucket: bucket) }
                           },
                           onShow: {
                               if let p = bucket.path {
                                   NSWorkspace.shared.activateFileViewerSelecting(
                                       [URL(fileURLWithPath: p)]
                                   )
                               }
                           })
            }
        }
    }

    private func cleanBucket(_ bucket: SystemDataReport.Bucket) {
        Task {
            let result: CleanupActions.Result
            // Snapshots are stored with path "/" (no real directory to clean)
            // and are removed via tmutil; everything else is a directory empty.
            if bucket.path == "/" {
                result = await CleanupActions.deleteLocalSnapshots()
            } else if let p = bucket.path {
                result = await CleanupActions.emptyDirectory(at: p, title: bucket.title)
            } else {
                return
            }
            await MainActor.run {
                lastResult = result
                model.systemReport = nil
                model.runSystemAnalysis()
            }
        }
    }
}

// MARK: - Bucket card

private struct BucketCard: View {
    let bucket: SystemDataReport.Bucket
    let totalBytes: Int64
    let onClean: () -> Void
    let onShow: () -> Void
    @State private var expanded: Bool = false

    private var fraction: Double {
        totalBytes > 0 ? Double(bucket.bytes) / Double(totalBytes) : 0
    }
    private var accentColor: Color {
        bucket.cleanable ? .green : .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(accentColor.opacity(0.18))
                            .frame(width: 38, height: 38)
                        Image(systemName: bucket.cleanable ? "sparkles" : "info.circle")
                            .foregroundStyle(accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(bucket.title).font(.body.weight(.semibold))
                            if bucket.cleanable {
                                Text("Safe to clean")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.green.opacity(0.18)))
                                    .foregroundStyle(.green)
                            }
                        }
                        if let p = bucket.path {
                            Text(p)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormatter.string(bucket.bytes))
                            .font(.body.monospaced().weight(.bold))
                        Text(String(format: "%.1f%%", fraction * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                        .font(.caption.weight(.semibold))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 12) {
                    Text(bucket.detail)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if bucket.path != nil {
                            Button(action: onShow) {
                                Label("Open in Finder", systemImage: "folder")
                            }
                        }
                        Spacer()
                        if bucket.cleanable {
                            Button(role: .destructive, action: onClean) {
                                Label("Empty Contents", systemImage: "trash")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Text("Manual cleanup only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
