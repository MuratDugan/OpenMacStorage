import SwiftUI

struct SidebarView: View {
    @Binding var selection: ContentView.Sidebar
    var fdaGranted: Bool = true
    @Environment(ScanModel.self) private var model

    var body: some View {
        List(selection: $selection) {
            if !fdaGranted {
                Section {
                    Button {
                        NotificationCenter.default.post(name: .showPermissionFlow, object: nil)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Limited access")
                                    .font(.callout.weight(.semibold))
                                Text("Grant Full Disk Access")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.12)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                row(.overview, "Overview", "chart.pie.fill")
                row(.browse, "Browse", "folder.fill")
                row(.treemap, "Treemap", "square.grid.3x3.fill")
                row(.search, "Search", "magnifyingglass")
            }
            Section("Tools") {
                row(.duplicates, "Duplicates", "doc.on.doc.fill")
                row(.oldFiles, "Old Downloads", "calendar.badge.clock")
                row(.appUninstaller, "Uninstall App", "trash.square")
                row(.scanDiff, "What Grew?", "chart.line.uptrend.xyaxis")
                row(.fileTypes, "File Types", "doc.richtext")
            }
            Section("Diagnostics") {
                row(.systemData, "System Data", "questionmark.circle.fill")
                row(.cleanup, "Cleanup", "sparkles")
            }
            Section("Disk") {
                VolumeBar(volume: model.volume)
                    .padding(.vertical, 6)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(_ value: ContentView.Sidebar, _ title: LocalizedStringKey, _ icon: String) -> some View {
        Label(title, systemImage: icon).tag(value)
    }
}

struct VolumeBar: View {
    let volume: VolumeInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(volume.name).font(.subheadline).bold()
            GeometryReader { geo in
                let frac = volume.totalCapacity > 0 ? Double(volume.usedCapacity) / Double(volume.totalCapacity) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, CGFloat(frac) * geo.size.width))
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(ByteFormatter.string(volume.usedCapacity)) used")
                Spacer()
                Text("\(ByteFormatter.string(volume.availableCapacity)) free")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
