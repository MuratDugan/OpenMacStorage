import SwiftUI
import AppKit

// MARK: - Public view

struct TreemapPaneView: View {
    @Environment(ScanModel.self) private var model
    @State private var stack: [FileNode] = []
    @State private var hovered: HoverInfo?
    @State private var depth: Int = 4
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    private var current: FileNode? { stack.last ?? model.rootNode }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.thinMaterial)
            Divider()
            content
        }
    }

    // MARK: Layered canvas + floating tooltip

    @ViewBuilder
    private var content: some View {
        if let root = current, root.size > 0 {
            GeometryReader { geo in
                let canvasRect = CGRect(origin: .zero, size: geo.size)
                let layouts = TreemapLayout.compute(node: root,
                                                    rect: canvasRect,
                                                    depth: depth)
                ZStack {
                    treemapCanvas(layouts: layouts, size: geo.size)
                    if let h = hovered {
                        TooltipBubble(info: h)
                            .position(clampedTooltipCenter(for: h.point, in: geo.size))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .background(Color.black.opacity(0.05))
            }
        } else {
            ContentUnavailableView("Scan required for treemap",
                                   systemImage: "square.grid.3x3")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { stack.removeLast(); resetView() } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .disabled(stack.isEmpty)

            Button { stack.removeAll(); resetView() } label: {
                Label("Root", systemImage: "house")
            }
            .disabled(stack.isEmpty)

            Divider().frame(height: 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if let root = model.rootNode {
                        crumb(root.name, isLast: stack.isEmpty) {
                            stack = []; resetView()
                        }
                        ForEach(Array(stack.enumerated()), id: \.element.id) { idx, n in
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary).font(.caption)
                            crumb(n.name, isLast: idx == stack.count - 1) {
                                stack = Array(stack.prefix(idx + 1)); resetView()
                            }
                        }
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Stepper("Depth: \(depth)", value: $depth, in: 1...8).fixedSize()

            if zoom != 1.0 || pan != .zero {
                Button { resetView() } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
            }
        }
    }

    private func crumb(_ name: String, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(.caption, design: .rounded).weight(isLast ? .bold : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Canvas + gestures

    @ViewBuilder
    private func treemapCanvas(layouts: [TreemapLayout.Tile], size: CGSize) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            // Draw non-hovered tiles first, hovered tile last so it sits on top.
            let hoveredID = hovered?.node.id
            for tile in layouts where tile.node.id != hoveredID {
                drawTile(context: context, tile: tile, isHovered: false)
            }
            if let hoveredID, let tile = layouts.first(where: { $0.node.id == hoveredID }) {
                drawTile(context: context, tile: tile, isHovered: true)
            }
        }
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(pan)
        // Explicit hit shape so trackpad gestures land on the canvas reliably.
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let raw):
                let local = inverseTransform(raw)
                if let tile = layouts.last(where: { $0.rect.contains(local) }) {
                    hovered = HoverInfo(node: tile.node, depth: tile.depth, point: raw)
                } else {
                    hovered = nil
                }
            case .ended:
                hovered = nil
            }
        }
        .onTapGesture(count: 2) {
            if let n = hovered?.node { drillDown(n) }
        }
        // Both gestures run in parallel via `simultaneousGesture` — using the
        // exclusive `.gesture` modifier on macOS suppresses the other one.
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    // Pinch zoom anchored at the cursor so the point under the
                    // fingers stays put on screen.
                    //
                    // We model the canvas as `screen = canvas * zoom + pan`.
                    // To keep the cursor's underlying canvas point fixed:
                    //     newPan = cursor − (cursor − lastPan) · (newZoom / lastZoom)
                    let newZoom = max(1.0, min(8.0, lastZoom * value.magnification))
                    let cursor = value.startLocation
                    let factor = newZoom / lastZoom
                    zoom = newZoom
                    pan = CGSize(
                        width:  cursor.x - (cursor.x - lastPan.width)  * factor,
                        height: cursor.y - (cursor.y - lastPan.height) * factor
                    )
                }
                .onEnded { _ in
                    if zoom <= 1.001 {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            zoom = 1.0
                            pan = .zero
                        }
                    }
                    lastZoom = zoom
                    lastPan = pan
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard zoom > 1.0 else { return }
                    pan = CGSize(width: lastPan.width + value.translation.width,
                                 height: lastPan.height + value.translation.height)
                }
                .onEnded { _ in lastPan = pan }
        )
        .contextMenu {
            if let n = hovered?.node {
                Button("Drill In") { drillDown(n) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)])
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: stack.count)
    }

    // MARK: - Drawing

    private func drawTile(context: GraphicsContext,
                          tile: TreemapLayout.Tile,
                          isHovered: Bool) {
        // Inset so adjacent tiles get a hairline gap.
        let inset: CGFloat = tile.rect.width > 18 && tile.rect.height > 18 ? 0.75 : 0.4
        let r = tile.rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0.5, r.height > 0.5 else { return }

        let radius = min(2.5, min(r.width, r.height) * 0.18)
        let path = Path(roundedRect: r, cornerRadius: radius)

        let baseColor = tintColor(for: tile.node)
        // Vertical gradient gives a sense of depth without being noisy.
        let topAlpha:    Double = isHovered ? 0.95 : 0.72
        let bottomAlpha: Double = isHovered ? 0.78 : 0.50
        context.fill(path, with: .linearGradient(
            Gradient(colors: [
                baseColor.opacity(topAlpha),
                baseColor.opacity(bottomAlpha)
            ]),
            startPoint: CGPoint(x: r.midX, y: r.minY),
            endPoint:   CGPoint(x: r.midX, y: r.maxY)
        ))

        // Outline. Hovered: bright. Default: subtle dark separator.
        let strokeColor: Color = isHovered ? .white : .black.opacity(0.35)
        let strokeWidth: CGFloat = isHovered ? 1.4 : 0.5
        context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)

        // Glow on hover.
        if isHovered {
            var glow = context
            glow.addFilter(.blur(radius: 7))
            glow.stroke(path, with: .color(baseColor.opacity(0.85)), lineWidth: 5)
        }

        // Label rendering — only when there's enough room. Two-line layout:
        // bold name on top, monospaced size below.
        let canShowTitle = r.width > 56 && r.height > 22
        let canShowSize  = r.width > 70 && r.height > 38
        if canShowTitle {
            let titleSize = max(10.0, min(13.0, Double(r.height) / 4.0))
            let title = Text(tile.node.name)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            // Subtle drop shadow for legibility on lighter category fills.
            var labeled = context
            labeled.addFilter(.shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1))
            labeled.draw(title,
                         in: CGRect(x: r.minX + 6, y: r.minY + 4,
                                    width: r.width - 10, height: titleSize + 4))
        }
        if canShowSize {
            let subSize = max(9.0, min(11.0, Double(r.height) / 5.0))
            let sub = Text(ByteFormatter.string(tile.node.size))
                .font(.system(size: subSize, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            context.draw(sub,
                         in: CGRect(x: r.minX + 6, y: r.minY + 22,
                                    width: r.width - 10, height: subSize + 2))
        }
    }

    // MARK: - Color helpers

    /// Subtle gray variants used for `.other` nodes. Same hue family as the
    /// neutral gray, but slight cool/warm/teal/mauve shifts so siblings in a
    /// treemap can still be told apart visually.
    private static let otherVariants: [Color] = [
        Color(red: 0.52, green: 0.56, blue: 0.62),  // neutral
        Color(red: 0.56, green: 0.54, blue: 0.62),  // mauve-gray
        Color(red: 0.52, green: 0.58, blue: 0.60),  // sage-gray
        Color(red: 0.58, green: 0.56, blue: 0.54),  // warm gray
        Color(red: 0.50, green: 0.58, blue: 0.62),  // slate-blue
        Color(red: 0.55, green: 0.60, blue: 0.55),  // olive-gray
        Color(red: 0.60, green: 0.55, blue: 0.58),  // dusty rose
        Color(red: 0.50, green: 0.54, blue: 0.58),  // steel
    ]

    private func tintColor(for node: FileNode) -> Color {
        guard node.category == .other else { return node.category.color }
        // Stable per-path index — same path always produces the same colour.
        let h = abs(node.path.hashValue)
        return Self.otherVariants[h % Self.otherVariants.count]
    }

    // MARK: - Helpers

    private func inverseTransform(_ raw: CGPoint) -> CGPoint {
        // Canvas was scaled (anchor=topLeading) then offset by `pan`. To go from
        // pointer (view) coordinates back into the canvas's untransformed space,
        // first remove pan, then divide by zoom.
        CGPoint(x: (raw.x - pan.width)  / zoom,
                y: (raw.y - pan.height) / zoom)
    }

    private func clampedTooltipCenter(for cursor: CGPoint, in size: CGSize) -> CGPoint {
        // Tooltip is ~320×96. Place it down-right of the cursor, but clamp so
        // it never escapes the canvas.
        let w: CGFloat = 320, h: CGFloat = 96
        var x = cursor.x + 14 + w / 2
        var y = cursor.y + 14 + h / 2
        x = min(max(w / 2 + 8, x), size.width  - w / 2 - 8)
        y = min(max(h / 2 + 8, y), size.height - h / 2 - 8)
        return CGPoint(x: x, y: y)
    }

    private func drillDown(_ node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            return
        }
        stack.append(node)
        resetView()
    }

    private func resetView() {
        withAnimation(.easeInOut(duration: 0.18)) {
            zoom = 1.0
            lastZoom = 1.0
            pan = .zero
            lastPan = .zero
        }
    }
}

// MARK: - Hover model

private struct HoverInfo: Equatable {
    let node: FileNode
    let depth: Int
    let point: CGPoint
    static func == (lhs: HoverInfo, rhs: HoverInfo) -> Bool {
        lhs.node.id == rhs.node.id
    }
}

// MARK: - Tooltip

private struct TooltipBubble: View {
    let info: HoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: info.node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(info.node.category.color)
                Text(info.node.name)
                    .font(.callout.bold())
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(ByteFormatter.string(info.node.size))
                    .font(.body.monospaced().weight(.semibold))
                Text(info.node.category.localizedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if info.node.isDirectory {
                Text("\(info.node.fileCount) files")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(info.node.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        // Solid (rather than translucent material) background so secondary text
        // doesn't bleed into whatever is behind. Adapts to light/dark mode via
        // semantic colours.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

// MARK: - Layout

enum TreemapLayout {
    struct Tile: Sendable {
        let node: FileNode
        let rect: CGRect
        let depth: Int
    }

    /// Compute squarified tiles for the entire visible subtree.
    static func compute(node: FileNode, rect: CGRect, depth: Int) -> [Tile] {
        var out: [Tile] = []
        layout(node: node, rect: rect, depth: depth, currentDepth: 0, into: &out)
        return out
    }

    private static func layout(node: FileNode,
                               rect: CGRect,
                               depth: Int,
                               currentDepth: Int,
                               into out: inout [Tile]) {
        guard rect.width > 1, rect.height > 1 else { return }

        let visibleChildren = node.children
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }

        if depth == 0 || visibleChildren.isEmpty {
            out.append(Tile(node: node, rect: rect, depth: currentDepth))
            return
        }

        let tiles = squarify(items: visibleChildren.map { ($0, Double($0.size)) },
                             rect: rect)

        for (child, childRect) in tiles {
            guard childRect.width > 1.5, childRect.height > 1.5 else { continue }
            let inner = childRect.insetBy(dx: 0.5, dy: 0.5)
            layout(node: child,
                   rect: inner,
                   depth: depth - 1,
                   currentDepth: currentDepth + 1,
                   into: &out)
        }
    }

    // MARK: - Squarified treemap (Bruls/van Wijk/Huijing 2000)

    fileprivate static func squarify(items: [(FileNode, Double)],
                                     rect: CGRect) -> [(FileNode, CGRect)] {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let totalWeight = items.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return [] }

        // Scale weights to pixel area so aspect ratios are computed in pixels.
        let totalArea = Double(rect.width) * Double(rect.height)
        let scale = totalArea / totalWeight
        var queue = items.map { (node: $0.0, area: $0.1 * scale) }

        var result: [(FileNode, CGRect)] = []
        var remaining = rect

        while !queue.isEmpty {
            let shorter = Double(min(remaining.width, remaining.height))
            guard shorter > 0 else { break }

            // Greedily extend the row while aspect ratio keeps improving.
            var rowCount = 1
            var bestWorst = worst(rowSlice: queue.prefix(1).map(\.area), side: shorter)
            while rowCount < queue.count {
                let nextWorst = worst(rowSlice: queue.prefix(rowCount + 1).map(\.area),
                                      side: shorter)
                if nextWorst > bestWorst { break }
                bestWorst = nextWorst
                rowCount += 1
            }

            let row = Array(queue.prefix(rowCount))
            queue.removeFirst(rowCount)
            let rowSum = row.reduce(0) { $0 + $1.area }

            if remaining.width >= remaining.height {
                let stripW = CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for (i, item) in row.enumerated() {
                    let isLast = i == row.count - 1
                    let h: CGFloat = isLast
                        ? remaining.maxY - y                              // close out exactly
                        : CGFloat(item.area / rowSum) * remaining.height
                    result.append((item.node,
                                   CGRect(x: remaining.minX, y: y,
                                          width: stripW, height: h)))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + stripW,
                                   y: remaining.minY,
                                   width: remaining.width - stripW,
                                   height: remaining.height)
            } else {
                let stripH = CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for (i, item) in row.enumerated() {
                    let isLast = i == row.count - 1
                    let w: CGFloat = isLast
                        ? remaining.maxX - x
                        : CGFloat(item.area / rowSum) * remaining.width
                    result.append((item.node,
                                   CGRect(x: x, y: remaining.minY,
                                          width: w, height: stripH)))
                    x += w
                }
                remaining = CGRect(x: remaining.minX,
                                   y: remaining.minY + stripH,
                                   width: remaining.width,
                                   height: remaining.height - stripH)
            }
        }

        return result
    }

    private static func worst(rowSlice: [Double], side: Double) -> Double {
        guard !rowSlice.isEmpty, side > 0 else { return .infinity }
        let s = rowSlice.reduce(0, +)
        guard s > 0 else { return .infinity }
        let mn = rowSlice.min() ?? 1
        let mx = rowSlice.max() ?? 1
        let s2 = s * s
        let side2 = side * side
        return Swift.max(side2 * mx / s2, s2 / (side2 * mn))
    }
}
