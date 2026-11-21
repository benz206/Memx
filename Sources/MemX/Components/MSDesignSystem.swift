import SwiftUI
import AppKit

// MARK: - Design Tokens

enum MS {
    // MARK: Radius
    enum Radius {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 6
        static let md:  CGFloat = 8
        static let lg:  CGFloat = 12
        static let xl:  CGFloat = 16
        static let full: CGFloat = 9999
    }

    // MARK: Spacing
    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 16
        static let lg:  CGFloat = 24
        static let xl:  CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Height {
        static let controlSmall: CGFloat = 26
        static let control: CGFloat = 30
        static let bar: CGFloat = 44
    }

    // MARK: Typography
    enum Font {
        static var displayLarge: SwiftUI.Font  { .system(size: 24, weight: .semibold) }
        static var displayMedium: SwiftUI.Font { .system(size: 20, weight: .semibold) }
        static var title: SwiftUI.Font         { .system(size: 15, weight: .semibold) }
        static var heading: SwiftUI.Font       { .system(size: 13, weight: .semibold) }
        static var button: SwiftUI.Font        { .system(size: 13, weight: .medium) }
        static var body: SwiftUI.Font          { .system(size: 13, weight: .regular) }
        static var caption: SwiftUI.Font       { .system(size: 12, weight: .regular) }
        static var micro: SwiftUI.Font         { .system(size: 11, weight: .medium) }
        static var eyebrow: SwiftUI.Font       { .system(size: 10.5, weight: .semibold) }
        static var stat: SwiftUI.Font          { .system(size: 20, weight: .semibold) }
        static var mono: SwiftUI.Font          { .system(size: 11.5, weight: .regular, design: .monospaced) }
    }

    // MARK: Shadow
    enum Shadow {
        static let subtle = (color: Color.black.opacity(0.06), radius: CGFloat(4), x: CGFloat(0), y: CGFloat(2))
        static let strong = (color: Color.black.opacity(0.18), radius: CGFloat(24), x: CGFloat(0), y: CGFloat(8))
    }
}

// MARK: - Color Roles

enum MSColor {
    static let canvas     = dynamic(light: 0xF7F7F8, dark: 0x111113)
    static let canvasDeep = dynamic(light: 0xF0F0F2, dark: 0x0B0B0D)
    static let surface    = dynamic(light: 0xFFFFFF, dark: 0x19191C)
    static let surface2   = dynamic(light: 0xF1F1F3, dark: 0x232327)
    static let line       = dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let lineStrong = dynamic(light: 0x000000, lightAlpha: 0.15, dark: 0xFFFFFF, darkAlpha: 0.15)
    static let inkBright  = dynamic(light: 0x111113, dark: 0xF4F4F5)
    static let ink        = dynamic(light: 0x2A2A2E, dark: 0xD9D9DE)
    static let inkMuted   = dynamic(light: 0x6B6B73, dark: 0x9A9AA3)
    static let inkFaint   = dynamic(light: 0x9C9CA4, dark: 0x6A6A73)
    static let onInverse  = dynamic(light: 0xFFFFFF, dark: 0x111113)

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger  = Color(nsColor: .systemRed)
    static let info    = Color(nsColor: .systemBlue)

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1,
                                dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

// MARK: - Card Modifier

struct MSCard: ViewModifier {
    var padding: CGFloat = MS.Spacing.md
    var radius: CGFloat = MS.Radius.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(MSColor.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(MSColor.line, lineWidth: 1)
            )
    }
}

extension View {
    func msCard(padding: CGFloat = MS.Spacing.md, radius: CGFloat = MS.Radius.lg) -> some View {
        modifier(MSCard(padding: padding, radius: radius))
    }

    func msShadow() -> some View {
        shadow(color: MS.Shadow.strong.color, radius: MS.Shadow.strong.radius,
               x: MS.Shadow.strong.x, y: MS.Shadow.strong.y)
    }

    func msEyebrow() -> some View {
        font(MS.Font.eyebrow)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(MSColor.inkFaint)
    }

    func msPage(maxWidth: CGFloat = 960) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, MS.Spacing.xl)
            .padding(.vertical, MS.Spacing.lg)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Buttons

struct MSButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, danger }
    enum Size { case small, regular }

    var variant: Variant = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        MSButtonBody(configuration: configuration, variant: variant, size: size)
    }
}

private struct MSButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: MSButtonStyle.Variant
    let size: MSButtonStyle.Size

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MS.Radius.md - (size == .small ? 1 : 0), style: .continuous)
        configuration.label
            .font(size == .small ? .system(size: 12, weight: .medium) : MS.Font.button)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .small ? 9 : 12)
            .frame(height: size == .small ? MS.Height.controlSmall : MS.Height.control)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = isEnabled && $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary:   return MSColor.onInverse
        case .secondary: return MSColor.inkBright
        case .ghost:     return isHovered ? MSColor.inkBright : MSColor.inkMuted
        case .danger:    return MSColor.danger
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed
        switch variant {
        case .primary:
            return MSColor.inkBright.opacity(pressed ? 0.78 : (isHovered ? 0.88 : 1))
        case .secondary:
            return pressed ? MSColor.surface2.opacity(0.7) : (isHovered ? MSColor.surface2 : MSColor.surface)
        case .ghost:
            return pressed ? MSColor.surface2 : (isHovered ? MSColor.surface2.opacity(0.7) : .clear)
        case .danger:
            return MSColor.danger.opacity(pressed ? 0.16 : (isHovered ? 0.1 : 0))
        }
    }

    private var border: Color {
        switch variant {
        case .primary, .ghost: return .clear
        case .secondary:       return isHovered ? MSColor.lineStrong : MSColor.lineStrong.opacity(0.75)
        case .danger:          return MSColor.danger.opacity(0.3)
        }
    }
}

extension ButtonStyle where Self == MSButtonStyle {
    static func ms(_ variant: MSButtonStyle.Variant, size: MSButtonStyle.Size = .regular) -> MSButtonStyle {
        MSButtonStyle(variant: variant, size: size)
    }
}

// MARK: - Primary Button

struct MSPrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isLoading: Bool = false
    var size: MSButtonStyle.Size = .regular

    init(_ title: String, icon: String? = nil, isLoading: Bool = false,
         size: MSButtonStyle.Size = .regular, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MSButtonLabel(title: title, icon: icon, isLoading: isLoading)
        }
        .buttonStyle(.ms(.primary, size: size))
        .disabled(isLoading)
    }
}

// MARK: - Secondary Button

struct MSSecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isDestructive: Bool = false
    var size: MSButtonStyle.Size = .regular

    init(_ title: String, icon: String? = nil, isDestructive: Bool = false,
         size: MSButtonStyle.Size = .regular, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            MSButtonLabel(title: title, icon: icon, isLoading: false)
        }
        .buttonStyle(.ms(isDestructive ? .danger : .secondary, size: size))
    }
}

struct MSButtonLabel: View {
    let title: String
    let icon: String?
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
        }
    }
}

struct MSIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14)
        }
        .buttonStyle(.ms(.ghost, size: .small))
        .help(help)
    }
}

// MARK: - Page Header

struct MSPageHeader<Actions: View>: View {
    var eyebrow: String? = nil
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: MS.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(MS.Font.caption)
                        .foregroundStyle(MSColor.inkFaint)
                }
                Text(title)
                    .font(MS.Font.displayLarge)
                    .tracking(-0.4)
                    .foregroundStyle(MSColor.inkBright)
                if let subtitle {
                    Text(subtitle)
                        .font(MS.Font.body)
                        .foregroundStyle(MSColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: MS.Spacing.md)
            HStack(spacing: MS.Spacing.sm) { actions() }
        }
    }
}

extension MSPageHeader where Actions == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Section Header

struct MSSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var count: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(MS.Font.heading)
                    .foregroundStyle(MSColor.inkBright)
                if let count {
                    Text("\(count)")
                        .font(MS.Font.heading.weight(.regular))
                        .foregroundStyle(MSColor.inkFaint)
                        .monospacedDigit()
                }
            }
            if let sub = subtitle {
                Text(sub)
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkMuted)
            }
        }
    }
}

// MARK: - Panel Header

struct MSPanelHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: MS.Spacing.sm) {
            MSSectionHeader(title: title, count: count)
            Spacer(minLength: MS.Spacing.sm)
            trailing()
        }
        .padding(.horizontal, MS.Spacing.md)
        .frame(height: MS.Height.bar)
        .overlay(alignment: .bottom) { MSDivider() }
    }
}

extension MSPanelHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

// MARK: - Stat Strip

struct MSStat: Identifiable {
    let label: String
    let value: String
    var sub: String? = nil
    var id: String { label }
}

struct MSStatStrip: View {
    let stats: [MSStat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 { MSVerticalDivider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(stat.label)
                        .font(MS.Font.caption)
                        .foregroundStyle(MSColor.inkMuted)
                        .lineLimit(1)
                    Text(stat.value)
                        .font(MS.Font.stat)
                        .tracking(-0.3)
                        .monospacedDigit()
                        .foregroundStyle(MSColor.inkBright)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let sub = stat.sub {
                        Text(sub)
                            .font(MS.Font.micro.weight(.regular))
                            .foregroundStyle(MSColor.inkFaint)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(MS.Spacing.md)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .msCard(padding: 0)
    }
}

// MARK: - Stat Row

struct MSStatRow: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: MS.Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(MSColor.inkFaint)
                    .frame(width: 16)
            }
            Text(label)
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkMuted)
            Spacer(minLength: MS.Spacing.sm)
            Text(value)
                .font(MS.Font.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(MSColor.inkBright)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Callout

struct MSCallout<Trailing: View>: View {
    enum Tone { case info, success, warning, danger }

    var tone: Tone = .info
    var title: String? = nil
    let message: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MS.Spacing.sm + 2) {
            MSStatusDot(color: color)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(MS.Font.body.weight(.medium))
                        .foregroundStyle(tone == .info ? MSColor.inkBright : color)
                }
                Text(message)
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: MS.Spacing.sm)
            trailing()
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, 10)
        .background(tone == .info ? MSColor.surface : color.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous)
                .strokeBorder(tone == .info ? MSColor.line : color.opacity(0.25), lineWidth: 1)
        )
    }

    private var color: Color {
        switch tone {
        case .info:    return MSColor.inkFaint
        case .success: return MSColor.success
        case .warning: return MSColor.warning
        case .danger:  return MSColor.danger
        }
    }
}

extension MSCallout where Trailing == EmptyView {
    init(tone: Tone = .info, title: String? = nil, message: String) {
        self.init(tone: tone, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Status Dot

struct MSStatusDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

// MARK: - Skeleton / Shimmer

struct MSSkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = MS.Radius.xs

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(MSColor.surface2)
            .opacity(dim ? 0.55 : 1)
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Badge

struct MSBadge: View {
    let text: String
    var color: Color = .secondary
    var size: BadgeSize = .regular
    var showsDot: Bool = false

    enum BadgeSize { case small, regular }

    private var isNeutral: Bool { color == .secondary }

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(isNeutral ? MSColor.inkFaint : color).frame(width: 6, height: 6)
            }
            Text(text)
                .font(size == .small ? .system(size: 11, weight: .medium) : .system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(isNeutral ? MSColor.inkMuted : color)
        .padding(.horizontal, size == .small ? 6 : 7)
        .frame(height: size == .small ? 18 : 20)
        .background(isNeutral ? MSColor.surface2 : color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: MS.Radius.sm - 1, style: .continuous))
    }
}

struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Divider

struct MSDivider: View {
    var orientation: Axis = .horizontal

    var body: some View {
        if orientation == .horizontal {
            Rectangle()
                .fill(MSColor.line)
                .frame(height: 1)
        } else {
            Rectangle()
                .fill(MSColor.line)
                .frame(width: 1)
        }
    }
}

struct MSVerticalDivider: View {
    var body: some View {
        MSDivider(orientation: .vertical)
    }
}

// MARK: - Window Background

struct MSGradientBackground: View {
    var body: some View {
        MSColor.canvas
            .ignoresSafeArea()
    }
}

// MARK: - Shared Display Mappings

extension ProjectStatus {
    var displayColor: Color {
        switch self {
        case .draft:        return .secondary
        case .analyzing:    return MSColor.warning
        case .configuring:  return .secondary
        case .ready:        return MSColor.success
        case .exported:     return MSColor.info
        }
    }

    var displayName: String {
        self == .exported ? "Rendered" : rawValue
    }
}

extension SectionType {
    var displayColor: Color {
        switch self {
        case .intro, .outro:  return .gray
        case .verse:          return .blue
        case .preChorus:      return .teal
        case .chorus:         return .indigo
        case .buildup:        return .orange
        case .drop:           return .red
        case .bridge:         return .purple
        case .breakdown:      return .mint
        }
    }
}
