import SwiftUI

// MARK: - Design Tokens

enum MS {
    // MARK: Radius
    enum Radius {
        static let xs:  CGFloat = 6
        static let sm:  CGFloat = 10
        static let md:  CGFloat = 14
        static let lg:  CGFloat = 18
        static let xl:  CGFloat = 24
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
    enum Font {
        static var displayLarge: SwiftUI.Font  { .system(size: 40, weight: .bold, design: .rounded) }
        static var displayMedium: SwiftUI.Font { .system(size: 30, weight: .bold, design: .rounded) }
        static var title: SwiftUI.Font         { .system(size: 22, weight: .semibold, design: .rounded) }
        static var heading: SwiftUI.Font       { .system(size: 17, weight: .semibold, design: .rounded) }
        static var button: SwiftUI.Font        { .system(size: 13, weight: .semibold, design: .rounded) }
        static var body: SwiftUI.Font          { .system(size: 14, weight: .regular, design: .default) }
        static var caption: SwiftUI.Font       { .system(size: 12, weight: .regular, design: .default) }
        static var micro: SwiftUI.Font         { .system(size: 10, weight: .medium, design: .monospaced) }
        static var mono: SwiftUI.Font          { .system(size: 12, weight: .regular, design: .monospaced) }
    }

    // MARK: Shadow
    enum Shadow {
        static let subtle = (color: Color.black.opacity(0.06), radius: CGFloat(4), x: CGFloat(0), y: CGFloat(2))
        static let strong = (color: Color.black.opacity(0.18), radius: CGFloat(24), x: CGFloat(0), y: CGFloat(8))
    }
}

// MARK: - Card Modifier

struct MSCard: ViewModifier {
    var padding: CGFloat = MS.Spacing.md
    var radius: CGFloat = MS.Radius.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: MS.Shadow.subtle.color, radius: MS.Shadow.subtle.radius, x: MS.Shadow.subtle.x, y: MS.Shadow.subtle.y)
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
                    ProgressView().controlSize(.small).tint(.white)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(MS.Font.button)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, MS.Spacing.md)
            .padding(.vertical, 7)
            .background(
                Color.accentColor.gradient,
                in: RoundedRectangle(cornerRadius: MS.Radius.full, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Secondary Button

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
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(MS.Font.button)
            }
            .foregroundStyle(isDestructive ? Color.red.opacity(0.85) : .primary)
            .padding(.horizontal, MS.Spacing.sm + 4)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: MS.Radius.full, style: .continuous))
            .overlay(
                isDestructive
                    ? RoundedRectangle(cornerRadius: MS.Radius.full, style: .continuous)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    : nil
            )
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 12))
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
            .padding(.horizontal, size == .small ? 5 : 8)
            .padding(.vertical, size == .small ? 2 : 3)
            .background(color.opacity(0.12), in: Capsule())
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

// MARK: - Accent Gradient Background

struct MSGradientBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.08), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 600
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.05), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 500
            )
        }
        .ignoresSafeArea()
    }
}
