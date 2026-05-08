import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScanModel.self) private var model
    @State private var selection: Sidebar = .overview
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer: Bool = false
    @State private var showDisclaimer: Bool = false
    @State private var reviewDisclaimer: Bool = false

    enum Sidebar: Hashable {
        case overview, browse, treemap, search
        case duplicates, oldFiles, appUninstaller, scanDiff, fileTypes
        case systemData, cleanup
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            Group {
                switch selection {
                case .overview:        OverviewView()
                case .browse:          BrowseView()
                case .treemap:         TreemapPaneView()
                case .search:          SearchView()
                case .duplicates:      DuplicatesView()
                case .oldFiles:        OldFilesView()
                case .appUninstaller:  AppUninstallerView()
                case .scanDiff:        ScanDiffView()
                case .fileTypes:       FileTypeStatsView()
                case .systemData:      SystemDataView()
                case .cleanup:         CleanupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .toolbar { ToolbarBar() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerView(onAccept: {
                hasAcceptedDisclaimer = true
                showDisclaimer = false
            })
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $reviewDisclaimer) {
            DisclaimerView(onAccept: {},
                           isReview: true,
                           onClose: { reviewDisclaimer = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDisclaimer)) { _ in
            reviewDisclaimer = true
        }
        .task {
            if model.systemReport == nil { model.runSystemAnalysis() }
            if !hasAcceptedDisclaimer { showDisclaimer = true }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard isDir.boolValue else { return }
            Task { @MainActor in
                model.startScan(root: url.path)
                selection = .overview
            }
        }
        return true
    }
}

private struct ToolbarBar: ToolbarContent {
    @Environment(ScanModel.self) private var model
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(model.rootCandidates, id: \.self) { p in
                    Button(p) { model.startScan(root: p) }
                }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label(shortPath(model.currentRoot), systemImage: "folder")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if case .scanning = model.phase {
                    Button(role: .destructive) { model.cancel() } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                } else {
                    Button { model.startScan() } label: {
                        Label("Scan", systemImage: "play.circle.fill")
                    }
                    .keyboardShortcut("r")
                }
            }
        }
    }

    private func shortPath(_ p: String) -> LocalizedStringKey {
        let home = NSString(string: "~").expandingTildeInPath
        if p == home { return "Home" }
        if p == "/" { return "Whole Disk" }
        let last = (p as NSString).lastPathComponent
        return LocalizedStringKey(last.isEmpty ? p : last)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a folder to scan")
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(root: url.path)
        }
    }
}
