import SwiftUI

// MARK: - ConfidenceBadge

struct ConfidenceBadge: View {
    let score: Float
    var style: BadgeStyle = .pill

    enum BadgeStyle { case pill, icon }

    var tier: Tier {
        switch score {
        case 0.85...: return .high
        case 0.65..<0.85: return .medium
        default: return .low
        }
    }

    enum Tier {
        case high, medium, low

        var label: String {
            switch self {
            case .high:   return "High"
            case .medium: return "Med"
            case .low:    return "Low"
            }
        }
        var color: Color {
            switch self {
            case .high:   return MSColor.success
            case .medium: return MSColor.warning
            case .low:    return MSColor.danger
            }
        }
    }

    var body: some View {
        switch style {
        case .pill:
            MSBadge(text: "\(Int(score * 100))% \(tier.label)", color: tier.color, size: .small, showsDot: true)

        case .icon:
            Text("\(Int(score * 100))")
                .font(MS.Font.mono)
                .foregroundStyle(tier == .low ? tier.color : MSColor.inkFaint)
                .help("\(Int(score * 100))% confidence")
        }
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: (title: String, handler: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MSColor.inkMuted)
                .frame(width: 40, height: 40)
                .background(MSColor.surface2, in: RoundedRectangle(cornerRadius: MS.Radius.md + 2, style: .continuous))
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MSColor.inkBright)
            Text(subtitle)
                .font(MS.Font.body)
                .foregroundStyle(MSColor.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)
            if let action {
                MSPrimaryButton(action.title, action: action.handler)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, MS.Spacing.lg)
        .padding(.vertical, 40)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous)
                .strokeBorder(MSColor.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(maxWidth: 480)
        )
        .padding(MS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
