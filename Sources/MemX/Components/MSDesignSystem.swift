import SwiftUI

// MARK: - Design Tokens

enum MS {
    // MARK: Radius
    enum Radius {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 6
        static let md:  CGFloat = 8
        static let lg:  CGFloat = 10
        static let xl:  CGFloat = 14
        static let full: CGFloat = 9999
    }

    // MARK: Spacing
    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 16
        static let lg:  CGFloat = 24
        static let xl:  CGFloat = 36
        static let xxl: CGFloat = 52
    }

    // MARK: Typography
    // Standard macOS text sizes: 13pt body, 11pt caption. No rounded faces.
    enum Font {
        static var displayLarge: SwiftUI.Font  { .system(size: 26, weight: .bold) }
        static var displayMedium: SwiftUI.Font { .system(size: 20, weight: .semibold) }
        static var title: SwiftUI.Font         { .system(size: 15, weight: .semibold) }
        static var heading: SwiftUI.Font       { .system(size: 13, weight: .semibold) }
        static var button: SwiftUI.Font        { .system(size: 13, weight: .medium) }
        static var body: SwiftUI.Font          { .system(size: 13, weight: .regular) }
        static var caption: SwiftUI.Font       { .system(size: 11, weight: .regular) }
        static var micro: SwiftUI.Font         { .system(size: 10, weight: .medium) }
        static var mono: SwiftUI.Font          { .system(size: 11, weight: .regular, design: .monospaced) }
    }

    // MARK: Shadow
    enum Shadow {
        static let subtle = (color: Color.black.opacity(0.06), radius: CGFloat(4), x: CGFloat(0), y: CGFloat(2))
        static let strong = (color: Color.black.opacity(0.18), radius: CGFloat(24), x: CGFloat(0), y: CGFloat(8))
    }
}

// MARK: - Card Modifier

/// Flat inspector-style group: quiet fill with a hairline border, no shadow.
struct MSCard: ViewModifier {
    var padding: CGFloat = MS.Spacing.md
    var radius: CGFloat = MS.Radius.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.quinary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            )
    }
}

extension View {
    func msCard(padding: CGFloat = MS.Spacing.md, radius: CGFloat = MS.Radius.md) -> some View {
        modifier(MSCard(padding: padding, radius: radius))
    }

    func msShadow() -> some View {
        shadow(color: MS.Shadow.strong.color, radius: MS.Shadow.strong.radius,
               x: MS.Shadow.strong.x, y: MS.Shadow.strong.y)
    }
}

// MARK: - Primary Button

/// Native prominent push button. Kept as a wrapper so call sites stay small.
struct MSPrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isLoading: Bool = false

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(isLoading)
    }
}

// MARK: - Secondary Button

/// Native bordered push button.
struct MSSecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isDestructive: Bool = false

    init(_ title: String, icon: String? = nil, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
            }
            .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

// MARK: - Section Header

struct MSSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(MS.Font.heading)
                .foregroundStyle(.primary)
            if let sub = subtitle {
                Text(sub)
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Stat Row

struct MSStatRow: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        HStack {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label)
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(MS.Font.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Skeleton / Shimmer

struct MSSkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = MS.Radius.xs

    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.secondary.opacity(0.12), location: phase - 0.3),
                        .init(color: Color.secondary.opacity(0.22), location: phase),
                        .init(color: Color.secondary.opacity(0.12), location: phase + 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

// MARK: - Badge

struct MSBadge: View {
    let text: String
    var color: Color = .secondary
    var size: BadgeSize = .regular

    enum BadgeSize { case small, regular }

    var body: some View {
        Text(text)
            .font(size == .small ? MS.Font.micro : MS.Font.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, size == .small ? 5 : 7)
            .padding(.vertical, size == .small ? 1.5 : 2.5)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous))
    }
}

// MARK: - Divider

struct MSDivider: View {
    var orientation: Axis = .horizontal

    var body: some View {
        if orientation == .horizontal {
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        } else {
            Rectangle()
                .fill(.separator)
                .frame(width: 0.5)
        }
    }
}

struct MSVerticalDivider: View {
    var body: some View {
        MSDivider(orientation: .vertical)
    }
}

// MARK: - Window Background

/// Plain window background. Name kept from the old gradient version so call
/// sites don't churn.
struct MSGradientBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

// MARK: - Shared Display Mappings

extension ProjectStatus {
    var displayColor: Color {
        switch self {
        case .draft:        return .secondary
        case .importing:    return .blue
        case .analyzing:    return .orange
        case .configuring:  return .teal
        case .ready:        return .green
        case .exported:     return .purple
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
