import SwiftUI
import AppKit

struct AppUninstallerView: View {
    @State private var apps: [String] = []
    @State private var query: String = ""
    @State private var selectedApp: String?
    @State private var report: AppUninstallReport?
    @State private var includeRelated: Set<UUID> = []
    @State private var analyzing = false
    @State private var pendingConfirm = false
    @State private var lastError: String?
    @State private var lastSuccess: String?

    private var filteredApps: [String] {
        guard !query.isEmpty else { return apps }
        return apps.filter {
            ((($0 as NSString).lastPathComponent as NSString).deletingPathExtension)
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 280)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { loadApps() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Applications")
                    .font(.title3.bold())
                Spacer()
                Button { loadApps() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.caption)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredApps, id: \.self) { p in
                        AppRow(path: p,
                               isSelected: selectedApp == p)
                        .onTapGesture { selectedApp = p }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Color.primary.opacity(0.02))
        .onChange(of: selectedApp) { _, new in
            if let new { analyze(appPath: new) }
        }
    }

    private func loadApps() {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications"]
        var found: [String] = []
        for r in roots {
            if let entries = try? fm.contentsOfDirectory(atPath: r) {
                for e in entries where e.hasSuffix(".app") {
                    found.append((r as NSString).appendingPathComponent(e))
                }
            }
        }
        // User-installed apps first, system apps after.
        apps = found.sorted { a, b in
            let aSys = a.hasPrefix("/System")
            let bSys = b.hasPrefix("/System")
            if aSys != bSys { return !aSys }
            return ((a as NSString).lastPathComponent.lowercased())
                 < ((b as NSString).lastPathComponent.lowercased())
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if analyzing {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Analyzing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = report {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appHeader(report: r)
                    if !r.related.isEmpty {
                        relatedSection(report: r)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 32))
                                .foregroundStyle(.green)
                            Text("No related files found.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                    }
                    actionBar(report: r)
                    if let lastSuccess {
                        StatusBanner(text: lastSuccess, color: .green, icon: "checkmark.circle.fill")
                    }
                    if let lastError {
                        StatusBanner(text: lastError, color: .orange, icon: "exclamationmark.triangle.fill")
                    }
                }
                .padding(28)
            }
            .alert("Confirm Uninstall", isPresented: $pendingConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash", role: .destructive) { performUninstall() }
            } message: {
                let total = r.appSize + r.related.filter { includeRelated.contains($0.id) }
                                                  .reduce(0) { $0 + $1.size }
                Text("\(r.appName) and \(includeRelated.count) related files (\(ByteFormatter.string(total))) will be moved to the Trash.")
            }
        } else {
            EmptyState(icon: "app.dashed",
                       title: "Pick an app",
                       message: "Select an app on the left to see what would be removed alongside it.")
        }
    }

    private func appHeader(report r: AppUninstallReport) -> some View {
        HStack(alignment: .top, spacing: 16) {
            AppIconImage(path: r.appPath, size: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.appName).font(.title.bold())
                if let id = r.bundleId {
                    Text(id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(r.appPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 14) {
                    Label("App body: \(ByteFormatter.string(r.appSize))", systemImage: "app.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("\(r.related.count) related",
                          systemImage: "puzzlepiece.extension.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.string(r.totalSize))
                    .font(.system(.title, design: .monospaced).weight(.bold))
                    .foregroundStyle(.green)
                Text("total recoverable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func relatedSection(report r: AppUninstallReport) -> some View {
        // Group by category for cleaner display.
        let grouped = Dictionary(grouping: r.related, by: \.category)
        let orderedKeys = grouped.keys.sorted {
            (grouped[$0]?.reduce(0) { $0 + $1.size } ?? 0) >
            (grouped[$1]?.reduce(0) { $0 + $1.size } ?? 0)
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Related Files").font(.headline)
                Spacer()
                Button("Select All") { includeRelated = Set(r.related.map(\.id)) }
                    .controlSize(.small)
                Button("Deselect All") { includeRelated = [] }
                    .controlSize(.small)
            }
            VStack(spacing: 10) {
                ForEach(orderedKeys, id: \.self) { category in
                    if let items = grouped[category] {
                        CategorySection(
                            categoryKey: category,
                            items: items,
                            includeRelated: $includeRelated
                        )
                    }
                }
            }
        }
    }

    private func actionBar(report r: AppUninstallReport) -> some View {
        let selectedSize = r.appSize + r.related
            .filter { includeRelated.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Will be moved to Trash").font(.caption).foregroundStyle(.secondary)
                Text(ByteFormatter.string(selectedSize))
                    .font(.title2.monospaced().weight(.bold))
                    .foregroundStyle(.red)
            }
            Spacer()
            Button(role: .destructive) {
                pendingConfirm = true
            } label: {
                Label("Uninstall \(r.appName)", systemImage: "trash.fill")
                    .padding(.horizontal, 8).padding(.vertical, 2)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.25)))
    }

    // MARK: - Actions

    private func analyze(appPath: String) {
        analyzing = true
        report = nil
        includeRelated = []
        Task {
            let r = await AppUninstaller.analyze(appPath: appPath)
            await MainActor.run {
                self.report = r
                self.includeRelated = Set(r.related.map(\.id))
                self.analyzing = false
            }
        }
    }

    private func performUninstall() {
        guard let r = report else { return }
        let failures = AppUninstaller.uninstall(report: r, includeRelated: includeRelated)
        if failures.isEmpty {
            lastSuccess = String(localized: "\(r.appName) and \(includeRelated.count) related files moved to Trash.")
            lastError = nil
            apps.removeAll { $0 == r.appPath }
            selectedApp = nil
            report = nil
        } else {
            lastError = String(localized: "Some files couldn't be moved: \(failures.count) errors.")
            lastSuccess = nil
        }
    }
}

// MARK: - App row in sidebar

private struct AppRow: View {
    let path: String
    let isSelected: Bool

    private var name: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
    private var isSystem: Bool { path.hasPrefix("/System") }

    var body: some View {
        HStack(spacing: 10) {
            AppIconImage(path: path, size: 22)
            Text(name)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if isSystem {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary).font(.caption2)
                    .help("System app")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(isSelected ? Color.white : .primary)
    }
}

// MARK: - Real app icon via NSWorkspace

private struct AppIconImage: View {
    let path: String
    let size: CGFloat

    var body: some View {
        let nsImage = NSWorkspace.shared.icon(forFile: path)
        Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .cornerRadius(size > 32 ? 12 : 4)
    }
}

// MARK: - Related-files category section

private struct CategorySection: View {
    let categoryKey: String
    let items: [AppRelatedFile]
    @Binding var includeRelated: Set<UUID>
    @State private var expanded = true

    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    private var allSelected: Bool {
        items.allSatisfy { includeRelated.contains($0.id) }
    }
    private var someSelected: Bool {
        items.contains { includeRelated.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(LocalizedStringKey(categoryKey))
                        .font(.callout.weight(.semibold))
                    Text("(\(items.count))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormatter.string(totalSize))
                        .font(.callout.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                    Toggle(isOn: Binding(
                        get: { allSelected },
                        set: { v in
                            if v { for it in items { includeRelated.insert(it.id) } }
                            else  { for it in items { includeRelated.remove(it.id) } }
                        })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().opacity(0.3)
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        RelatedFileRow(item: item, includeRelated: $includeRelated)
                        Divider().opacity(0.2)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct RelatedFileRow: View {
    let item: AppRelatedFile
    @Binding var includeRelated: Set<UUID>
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { includeRelated.contains(item.id) },
                set: { v in
                    if v { includeRelated.insert(item.id) }
                    else  { includeRelated.remove(item.id) }
                })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text(item.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormatter.string(item.size))
                .font(.body.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: item.path)]
                )
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .opacity(hovered ? 1.0 : 0.4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
    }
}

// `StatusBanner` is defined in CleanupView.swift (shared helper).
