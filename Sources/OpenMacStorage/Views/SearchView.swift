import SwiftUI
import AppKit

/// WizFile/Everything-style deep file search across the entire scanned tree.
/// Supports plain substring, full-path search, glob wildcards (`*.docx`,
/// `IMG_*.png`), and raw regex. Results are paginated, sortable, with
/// risk-aware bulk delete.
struct SearchView: View {
    @Environment(ScanModel.self) private var model

    @State private var query: String = ""
    @State private var mode: SearchMode = .name
    @State private var kindFilter: FileIconInfo.KindGroup = .all
    @State private var minMB: Double = 0
    @State private var sort: SortKey = .relevance
    @State private var results: [FileNode] = []
    @State private var totalMatched: Int = 0
    @State private var elapsedMs: Double = 0
    @State private var searching: Bool = false
    @State private var page: Int = 0
    @State private var selection: Set<UUID> = []
    @State private var debounce: Task<Void, Never>?
    @State private var pendingSearch: Bool = false  // true between keystroke and result
    @State private var pendingDelete: PendingDelete?
    @State private var lastError: String?
    @State private var regexError: String?

    private let pageSize = 200

    enum SearchMode: String, CaseIterable, Identifiable {
        case name, path, wildcard, regex
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .name: "Name contains"
            case .path: "Path contains"
            case .wildcard: "Wildcard"
            case .regex: "Regex"
            }
        }
        var icon: String {
            switch self {
            case .name: "textformat.abc"
            case .path: "folder.fill.badge.questionmark"
            case .wildcard: "asterisk"
            case .regex: "chevron.left.forwardslash.chevron.right"
            }
        }
        var placeholder: LocalizedStringKey {
            switch self {
            case .name: "Type to find files…"
            case .path: "Search the full path…"
            case .wildcard: "*.docx, IMG_*.png, *backup*"
            case .regex: "^build.*\\.log$"
            }
        }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case relevance, sizeDesc, sizeAsc, nameAsc, nameDesc, pathAsc
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .relevance: "Best match"
            case .sizeDesc:  "Size: largest"
            case .sizeAsc:   "Size: smallest"
            case .nameAsc:   "Name A → Z"
            case .nameDesc:  "Name Z → A"
            case .pathAsc:   "Path A → Z"
            }
        }
    }

    struct PendingDelete: Identifiable {
        let id = UUID()
        let nodes: [FileNode]
        var totalBytes: Int64 { nodes.reduce(0) { $0 + $1.size } }
        var maxRisk: RiskAssessment.Level {
            nodes.map { RiskClassifier.assess($0.path).level }.max() ?? .none
        }
    }

    /// Computed hint shown next to the search field — surfaces the auto-detected
    /// behaviour so users know why `*.docx` is suddenly working.
    private var detectedAutoMode: String? {
        guard mode == .name || mode == .path else { return nil }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return nil }
        if q.contains("*") || q.contains("?") {
            return String(localized: "auto: wildcard")
        }
        if q.hasPrefix(".") && !q.contains(" ") && q.count > 1 {
            return String(localized: "auto: extension")
        }
        return nil
    }

    private var pageCount: Int {
        max(1, (results.count + pageSize - 1) / pageSize)
    }
    private var pageEntries: [FileNode] {
        let s = page * pageSize
        let e = min(s + pageSize, results.count)
        return s < e ? Array(results[s..<e]) : []
    }
    private var selectedNodes: [FileNode] {
        results.filter { selection.contains($0.id) }
    }
    private var selectedSize: Int64 {
        selectedNodes.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(.thinMaterial)
            Divider()
            controls
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.regularMaterial)
            if let err = regexError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            Divider()
            content
            if !selection.isEmpty {
                Divider()
                selectionBar
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial)
            }
            if !results.isEmpty {
                Divider()
                paginationBar
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial)
            }
        }
        .alert("Move to Trash", isPresented: deleteBinding) {
            if let p = pendingDelete, p.maxRisk == .blocked {
                Button("OK") {}
            } else {
                Button("Cancel", role: .cancel) {}
                Button(deleteButton(), role: .destructive) { confirmDelete() }
            }
        } message: {
            if let p = pendingDelete { deleteMessage(p) } else { Text("") }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") {}
        } message: { Text(lastError ?? "") }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .foregroundStyle(.secondary).font(.title3)
                TextField(mode.placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .onSubmit { runSearch() }
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = ""; results = []; totalMatched = 0 } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 14) {
                // Tiny "auto-detected as wildcard" hint when applicable.
                if (mode == .name || mode == .path),
                   detectedAutoMode != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars.inverse")
                            .foregroundStyle(.purple).font(.caption)
                        Text(detectedAutoMode ?? "")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.purple)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                }
                if pendingSearch || searching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(pendingSearch && !searching ? "Waiting…" : "Searching…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if !results.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.green)
                        Text("**\(totalMatched)** matches")
                            .font(.callout)
                        Text("in \(String(format: "%.0f", elapsedMs)) ms")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else if !query.isEmpty {
                    Text("No matches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: mode) { _, _ in scheduleSearch() }
        .onChange(of: kindFilter) { _, _ in scheduleSearch() }
        .onChange(of: minMB) { _, _ in scheduleSearch() }
        .onChange(of: sort) { _, _ in resort() }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(SearchMode.allCases) { m in
                    Label(m.label, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)

            Picker("", selection: $kindFilter) {
                ForEach(FileIconInfo.KindGroup.allCases) { g in
                    Label(g.label, systemImage: g.icon).tag(g)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)

            Menu {
                Button("Any size") { minMB = 0 }
                Divider()
                ForEach([1, 10, 50, 100, 500, 1024], id: \.self) { mb in
                    Button(mb >= 1024 ? "≥ 1 GB" : "≥ \(mb) MB") {
                        minMB = Double(mb)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scalemass").font(.caption)
                    Text(minMB == 0 ? "Any size" :
                          (minMB >= 1024 ? "≥ 1 GB" : "≥ \(Int(minMB)) MB"))
                        .font(.callout)
                }
            }
            .menuStyle(.button)
            .frame(maxWidth: 130)

            Spacer()

            Picker("", selection: $sort) {
                ForEach(SortKey.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.rootNode == nil {
            EmptyState(icon: "doc.text.magnifyingglass",
                       title: "Scan first",
                       message: "A scan is required to search.")
        } else if query.isEmpty && kindFilter == .all && minMB == 0 {
            modeHint
        } else if pendingSearch || searching {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(pendingSearch && !searching ? "Waiting for you to finish typing…" : "Scanning the tree…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            EmptyState(icon: "tray",
                       title: "No matches",
                       message: "Try a different pattern, switch search mode, or loosen filters.")
        } else {
            Table(pageEntries, selection: $selection) {
                TableColumn("Name") { n in
                    HStack(spacing: 10) {
                        let info = FileIconInfo.forNode(n)
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(info.color.opacity(n.isDirectory ? 0.22 : 0.14))
                                .frame(width: 22, height: 22)
                            Image(systemName: info.symbol)
                                .foregroundStyle(info.color)
                                .font(.system(size: 12, weight: n.isDirectory ? .semibold : .regular))
                        }
                        Text(n.name)
                            .font(n.isDirectory ? .body.weight(.medium) : .body)
                            .lineLimit(1)
                        let risk = RiskClassifier.assess(n.path)
                        if risk.level >= .medium {
                            Image(systemName: risk.icon)
                                .foregroundStyle(risk.color)
                                .font(.caption)
                                .help(Text(risk.reason))
                        }
                    }
                    .contextMenu { rowMenu(n) }
                }
                TableColumn("Size") { n in
                    Text(ByteFormatter.string(n.size))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(110)
                TableColumn("Kind") { n in
                    Text(FileIconInfo.kindLabel(for: n))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 150)
                TableColumn("Path") { n in
                    Text(n.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(n.path)
                }
            }
        }
    }

    private var modeHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50)).foregroundStyle(.tertiary)
            Text("Find anything, anywhere").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                hintRow(icon: "textformat.abc",
                        title: "Name contains",
                        example: "report")
                hintRow(icon: "asterisk",
                        title: "Wildcard",
                        example: "*.docx, IMG_*.png, *backup*")
                hintRow(icon: "chevron.left.forwardslash.chevron.right",
                        title: "Regex",
                        example: "^build.*\\.log$")
                hintRow(icon: "folder.fill.badge.questionmark",
                        title: "Path contains",
                        example: "/Library/Caches/")
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        }
        .frame(maxWidth: 600)
        .frame(maxHeight: .infinity)
    }

    private func hintRow(icon: String, title: LocalizedStringKey, example: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(title).font(.callout.weight(.medium)).frame(width: 130, alignment: .leading)
            Text(example).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selection.count) selected")
                    .font(.callout.weight(.semibold))
                Text(ByteFormatter.string(selectedSize))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            let highest = selectedNodes.map { RiskClassifier.assess($0.path).level }.max() ?? .none
            if highest >= .medium {
                let assess = RiskAssessment(level: highest, reason: "")
                HStack(spacing: 4) {
                    Image(systemName: assess.icon).foregroundStyle(assess.color)
                    Text(assess.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(assess.color)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(assess.color.opacity(0.15)))
            }
            Spacer()
            Button { showInFinder(selectedNodes) } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            Button { copyPaths(selectedNodes) } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive) {
                pendingDelete = PendingDelete(nodes: selectedNodes)
            } label: {
                Label("Move to Trash (\(selection.count))", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    // MARK: - Pagination

    private var paginationBar: some View {
        HStack {
            Text("Showing \(page * pageSize + 1)–\(min((page + 1) * pageSize, results.count)) of \(results.count)")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Button { page = 0 } label: { Image(systemName: "chevron.backward.2") }
                    .disabled(page == 0)
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.backward") }
                    .disabled(page == 0)
                Text("Page \(page + 1) of \(pageCount)")
                    .font(.callout.monospaced()).frame(minWidth: 130)
                Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.forward") }
                    .disabled(page >= pageCount - 1)
                Button { page = pageCount - 1 } label: { Image(systemName: "chevron.forward.2") }
                    .disabled(page >= pageCount - 1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowMenu(_ n: FileNode) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(n.path, forType: .string)
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = PendingDelete(nodes: [n])
        } label: { Text("Move to Trash") }
    }

    // MARK: - Search execution

    /// Each keystroke / filter change goes through here. We mark the UI as
    /// "pending" right away so stale results aren't shown as the new answer,
    /// then wait 400 ms after the *last* change before actually scanning.
    private func scheduleSearch() {
        debounce?.cancel()
        pendingSearch = true
        debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            runSearch()
        }
    }

    private func runSearch() {
        guard let root = model.rootNode else {
            results = []; totalMatched = 0; pendingSearch = false; return
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let kind = kindFilter
        let bytes = Int64(minMB * 1024 * 1024)
        let mode = self.mode
        let sortKey = self.sort

        let matcher: SearchMatcher
        switch (mode, q) {
        case (_, "") where kind == .all && bytes == 0:
            results = []; totalMatched = 0
            pendingSearch = false
            return
        case (_, ""):
            matcher = .alwaysTrue

        case (.name, _):
            guard let m = autoMatcher(for: q, inPath: false) else {
                regexError = String(localized: "Invalid wildcard pattern.")
                pendingSearch = false
                return
            }
            matcher = m

        case (.path, _):
            guard let m = autoMatcher(for: q, inPath: true) else {
                regexError = String(localized: "Invalid wildcard pattern.")
                pendingSearch = false
                return
            }
            matcher = m

        case (.wildcard, _):
            do {
                let regex = try NSRegularExpression(pattern: globToRegex(q),
                                                    options: .caseInsensitive)
                matcher = .regex(regex, inPath: false)
                regexError = nil
            } catch {
                regexError = String(localized: "Invalid wildcard pattern.")
                pendingSearch = false
                return
            }
        case (.regex, _):
            do {
                let regex = try NSRegularExpression(pattern: q, options: .caseInsensitive)
                matcher = .regex(regex, inPath: false)
                regexError = nil
            } catch {
                regexError = String(localized: "Invalid regex: ") + error.localizedDescription
                pendingSearch = false
                return
            }
        }
        regexError = nil
        searching = true
        let started = Date()
        let queryForRanking = q.lowercased()
        Task.detached(priority: .userInitiated) {
            var hits: [FileNode] = []
            collect(node: root, matcher: matcher, kind: kind, minBytes: bytes, into: &hits)
            if sortKey == .relevance && !queryForRanking.isEmpty {
                sortByRelevance(&hits, query: queryForRanking)
            } else {
                sortHits(&hits, by: sortKey)
            }
            let elapsed = Date().timeIntervalSince(started) * 1000
            let snapshot = hits
            await MainActor.run {
                self.totalMatched = snapshot.count
                self.results = snapshot
                self.elapsedMs = elapsed
                self.searching = false
                self.pendingSearch = false
                self.page = 0
                self.selection = []
            }
        }
    }

    private func resort() {
        var copy = results
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if sort == .relevance && !q.isEmpty {
            sortByRelevance(&copy, query: q)
        } else {
            sortHits(&copy, by: sort)
        }
        results = copy
        page = 0
    }

    /// Pre-compiled matchers so each node hits exactly one branch.
    /// `fuzzyTokens` powers Name/Path modes — each whitespace-separated token
    /// must appear in the target, either as a substring or as an in-order
    /// subsequence (so "minka at" still finds "MINKA-IT").
    enum SearchMatcher: @unchecked Sendable {
        case alwaysTrue
        case fuzzyTokens(tokens: [String], inPath: Bool)
        case regex(NSRegularExpression, inPath: Bool)

        func matches(_ node: FileNode) -> Bool {
            switch self {
            case .alwaysTrue: return true
            case .fuzzyTokens(let tokens, let inPath):
                let target = (inPath ? node.path : node.name).lowercased()
                for token in tokens {
                    if !Self.fuzzyContains(token: token, in: target) { return false }
                }
                return true
            case .regex(let regex, let inPath):
                let target = inPath ? node.path : node.name
                let range = NSRange(target.startIndex..., in: target)
                return regex.firstMatch(in: target, options: [], range: range) != nil
            }
        }

        /// Token must appear in target. Tries substring first (fast path); if
        /// that fails, falls back to in-order subsequence so single-character
        /// typos are tolerated.
        static func fuzzyContains(token: String, in target: String) -> Bool {
            guard !token.isEmpty else { return true }
            if target.contains(token) { return true }
            // Subsequence: every char of `token` appears in `target` in order.
            var qi = token.startIndex
            var ti = target.startIndex
            while qi < token.endIndex && ti < target.endIndex {
                if token[qi] == target[ti] {
                    qi = token.index(after: qi)
                }
                ti = target.index(after: ti)
            }
            return qi == token.endIndex
        }
    }

    private nonisolated func collect(node: FileNode,
                                     matcher: SearchMatcher,
                                     kind: FileIconInfo.KindGroup,
                                     minBytes: Int64,
                                     into hits: inout [FileNode]) {
        // Don't include the synthetic root.
        if node.parent != nil {
            if matcher.matches(node) &&
               (kind == .all || kind.matches(node)) &&
               node.size >= minBytes {
                hits.append(node)
            }
        }
        for c in node.children {
            collect(node: c, matcher: matcher, kind: kind, minBytes: minBytes, into: &hits)
        }
    }

    private nonisolated func sortHits(_ hits: inout [FileNode], by key: SortKey) {
        switch key {
        case .relevance:
            // Relevance is computed against the current query — done at call site.
            // Fall back to size if no query is set.
            hits.sort { $0.size > $1.size }
        case .sizeDesc: hits.sort { $0.size > $1.size }
        case .sizeAsc:  hits.sort { $0.size < $1.size }
        case .nameAsc:  hits.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: hits.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .pathAsc:  hits.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        }
    }

    /// Sort hits by how relevant they are to `query`. Higher score wins.
    ///
    /// Signals (in order of strength):
    ///   • Whole query is a substring of the name.
    ///   • That substring starts at the name's beginning, or right after a word
    ///     boundary (space / `-` / `_` / `.`).
    ///   • All tokens are substrings of the name (regardless of order).
    ///   • Tokens are only matched via subsequence (weakest signal).
    /// Then we add a small bonus for shorter names — among items that match
    /// equally well, the more specific filename wins.
    private nonisolated func sortByRelevance(_ hits: inout [FileNode], query: String) {
        let q = query.lowercased()
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Tie-breaker fallback to size desc.
        hits.sort { a, b in
            let sa = Self.relevanceScore(name: a.name.lowercased(), path: a.path.lowercased(),
                                         query: q, tokens: tokens)
            let sb = Self.relevanceScore(name: b.name.lowercased(), path: b.path.lowercased(),
                                         query: q, tokens: tokens)
            if sa != sb { return sa > sb }
            return a.size > b.size
        }
    }

    fileprivate static func relevanceScore(name: String, path: String,
                                           query: String, tokens: [String]) -> Int {
        // Equal-string match → best possible.
        if name == query { return 100_000 }

        var score = 0

        // 1. Whole query as substring of the name.
        if let r = name.range(of: query) {
            score += 4_000
            if r.lowerBound == name.startIndex {
                score += 800
            } else {
                let before = name[name.index(before: r.lowerBound)]
                if "-_. /".contains(before) { score += 400 }
            }
        }

        // 2. Per-token name hits.
        var tokensFoundInName = 0
        for token in tokens where !token.isEmpty {
            if let r = name.range(of: token) {
                tokensFoundInName += 1
                score += 600
                if r.lowerBound == name.startIndex {
                    score += 200
                } else {
                    let before = name[name.index(before: r.lowerBound)]
                    if "-_. /".contains(before) { score += 80 }
                }
            } else if SearchMatcher.fuzzyContains(token: token, in: name) {
                score += 100   // subsequence only — weak
            } else if path.contains(token) {
                score += 30    // path-only token match — weakest
            }
        }

        // 3. Reward when every token landed in the name as a real substring.
        if !tokens.isEmpty && tokensFoundInName == tokens.count {
            score += 500
        }

        // 4. Penalise long names slightly so close matches outrank distant ones.
        score -= name.count / 4
        return score
    }

    /// Smart matcher for Name/Path modes:
    ///   • Query has `*` or `?` → treat as wildcard (e.g. `*.docx`).
    ///   • Query starts with `.` (and no whitespace) → shortcut for `*<ext>`
    ///     so typing `.pdf` finds every `.pdf`.
    ///   • Otherwise → fuzzy token matching (substring then subsequence).
    private func autoMatcher(for q: String, inPath: Bool) -> SearchMatcher? {
        if q.contains("*") || q.contains("?") {
            guard let regex = try? NSRegularExpression(pattern: globToRegex(q),
                                                       options: .caseInsensitive)
            else { return nil }
            return .regex(regex, inPath: inPath)
        }
        if q.hasPrefix(".") && !q.contains(" ") && q.count > 1 {
            let pattern = "*\(q)"
            guard let regex = try? NSRegularExpression(pattern: globToRegex(pattern),
                                                       options: .caseInsensitive)
            else { return nil }
            return .regex(regex, inPath: inPath)
        }
        let tokens = q.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return .fuzzyTokens(tokens: tokens, inPath: inPath)
    }

    /// Converts a shell-style glob (`*`, `?`) into a regex anchored at both
    /// ends. Other special regex characters get escaped.
    private nonisolated func globToRegex(_ pattern: String) -> String {
        var result = ""
        for char in pattern {
            switch char {
            case "*": result += ".*"
            case "?": result += "."
            case ".", "\\", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|":
                result += "\\\(char)"
            default:
                result.append(char)
            }
        }
        return "^\(result)$"
    }

    // MARK: - Delete

    private var deleteBinding: Binding<Bool> {
        .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
    private var errorBinding: Binding<Bool> {
        .init(get: { lastError != nil }, set: { if !$0 { lastError = nil } })
    }

    private func deleteMessage(_ p: PendingDelete) -> Text {
        switch p.maxRisk {
        case .blocked:
            return Text("**Refused.** Some items are protected and cannot be deleted from here. These are macOS system files.")
        case .high:
            return Text("⚠️ \(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes)))\n\nIncludes **app data** an installed application depends on.")
        case .medium:
            return Text("\(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes)))\n\nIncludes app preferences/saved state.")
        case .low, .none:
            return Text("\(p.nodes.count) items (\(ByteFormatter.string(p.totalBytes))) will be moved to the Trash.")
        }
    }

    private func deleteButton() -> LocalizedStringKey {
        guard let p = pendingDelete else { return "Move" }
        switch p.maxRisk {
        case .high:    return "I understand — Move to Trash"
        case .medium:  return "Move to Trash anyway"
        default:       return "Move to Trash"
        }
    }

    private func confirmDelete() {
        guard let p = pendingDelete else { return }
        pendingDelete = nil
        let toDelete = p.nodes.filter { RiskClassifier.assess($0.path).level != .blocked }
        var failures: [String] = []
        var deletedIds = Set<UUID>()
        for n in toDelete {
            if let err = CleanupActions.moveToTrash(n.path) {
                failures.append("• \((n.path as NSString).lastPathComponent): \(err.localizedDescription)")
            } else {
                deletedIds.insert(n.id)
            }
        }
        results.removeAll { deletedIds.contains($0.id) }
        totalMatched = results.count
        selection.subtract(deletedIds)
        if !failures.isEmpty {
            lastError = String(localized: "Some items couldn't be moved:") + "\n\n" +
                        failures.joined(separator: "\n")
        }
    }

    // MARK: - Misc helpers

    private func showInFinder(_ items: [FileNode]) {
        let urls = items.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(_ items: [FileNode]) {
        let paths = items.map { $0.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
