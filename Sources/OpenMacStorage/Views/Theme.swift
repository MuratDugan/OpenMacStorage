import SwiftUI

/// Design tokens shared by every screen. Views use these instead of raw
/// numbers/colours so spacing, corners, motion and semantic colours stay
/// consistent (and adapt to light/dark through system colours).
enum Theme {
    // 4-pt spacing scale
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 14
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.snappy(duration: 0.25)
    }

    // Semantic colours — never raw RGB in views.
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceRaised = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.07)

    /// Data that lives only in the cloud (no local blocks).
    static let cloud = Color(red: 0.35, green: 0.62, blue: 0.98)
    /// Space that can be safely reclaimed.
    static let reclaim = Color(red: 0.96, green: 0.62, blue: 0.10)
    /// Free space on the volume.
    static let free = Color.primary.opacity(0.10)
    /// Used space outside the scanned folder.
    static let outside = Color.primary.opacity(0.28)
    static let positive = Color.green
    static let caution = Color.orange
    static let danger = Color.red
}

// MARK: - Surfaces

private struct SurfaceCard: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline))
    }
}

extension View {
    /// Standard card container: surface fill + hairline border.
    func surfaceCard(padding: CGFloat = Theme.Space.l) -> some View {
        modifier(SurfaceCard(padding: padding))
    }
}

/// Title + optional subtitle, with an optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Space.s)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - Stats

struct StatPill: View {
    let label: LocalizedStringKey
    let value: String
    let color: Color
    let icon: String
    var footnote: LocalizedStringKey? = nil

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(label).font(.caption).foregroundStyle(.secondary)
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .surfaceCard(padding: Theme.Space.m)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Space.xxs)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// Small capsule tag ("In cloud", "Summarized"…). Always icon + text so the
/// meaning never depends on colour alone.
struct TagBadge: View {
    let text: LocalizedStringKey
    let icon: String
    var color: Color = .secondary

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Storage bar

/// One horizontal bar split into proportional segments (categories, space
/// outside the scan, free space) with a hover readout and a legend.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
        var hatched = false
    }

    let segments: [Segment]
    var height: CGFloat = 22
    var showsLegend = true

    @State private var hovered: String?

    private var total: Int64 { max(1, segments.reduce(0) { $0 + max(0, $1.bytes) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let visible = segments.filter { $0.bytes > 0 }
                let usable = max(0, geo.size.width - gap * CGFloat(max(0, visible.count - 1)))
                HStack(spacing: gap) {
                    ForEach(visible) { seg in
                        let w = max(3, usable * CGFloat(Double(seg.bytes) / Double(total)))
                        Rectangle()
                            .fill(seg.color)
                            .overlay {
                                if seg.hatched { Hatch().stroke(Color.primary.opacity(0.12), lineWidth: 1) }
                            }
                            .frame(width: w)
                            .opacity(hovered == nil || hovered == seg.id ? 1 : 0.45)
                            .onHover { inside in
                                withAnimation(Theme.Motion.quick) { hovered = inside ? seg.id : nil }
                            }
                            .help(Text(verbatim: "\(seg.label) — \(ByteFormatter.string(seg.bytes))"))
                            .accessibilityLabel(Text(verbatim: "\(seg.label), \(ByteFormatter.string(seg.bytes))"))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }
            .frame(height: height)

            if showsLegend {
                legend
            }
        }
    }

    private var legend: some View {
        let items = segments.filter { $0.bytes > 0 }
        return FlowLayout(spacing: Theme.Space.m, lineSpacing: Theme.Space.xs) {
            ForEach(items) { seg in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(seg.color)
                        .overlay { if seg.hatched { Hatch().stroke(Color.primary.opacity(0.15), lineWidth: 1) } }
                        .frame(width: 10, height: 10)
                    Text(seg.label).foregroundStyle(hovered == seg.id ? .primary : .secondary)
                    Text(ByteFormatter.string(seg.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .onHover { inside in
                    withAnimation(Theme.Motion.quick) { hovered = inside ? seg.id : nil }
                }
            }
        }
    }
}

/// Diagonal hatching for "not measured" segments.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 6
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return p
    }
}

/// Simple wrapping layout for legends and tag rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX; lineHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Thin proportional bar used in lists.
struct ShareBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(2, CGFloat(min(1, max(0, fraction))) * geo.size.width))
            }
        }
        .frame(height: height)
    }
}
