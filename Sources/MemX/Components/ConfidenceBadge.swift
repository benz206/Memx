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
            case .high:   return .green
            case .medium: return .orange
            case .low:    return .red
            }
        }
        var icon: String {
            switch self {
            case .high:   return "checkmark.seal.fill"
            case .medium: return "minus.circle.fill"
            case .low:    return "exclamationmark.triangle.fill"
            }
        }
    }

    var body: some View {
        switch style {
        case .pill:
            HStack(spacing: 4) {
                Circle()
                    .fill(tier.color)
                    .frame(width: 6, height: 6)
                Text("\(Int(score * 100))% \(tier.label)")
                    .font(MS.Font.micro)
                    .foregroundStyle(tier.color)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tier.color.opacity(0.1), in: Capsule())

        case .icon:
            Image(systemName: tier.icon)
                .font(.system(size: 12))
                .foregroundStyle(tier.color)
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
        VStack(spacing: MS.Spacing.md) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(MS.Font.heading)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            if let action {
                MSPrimaryButton(action.title, action: action.handler)
                    .padding(.top, 4)
            }
        }
        .padding(MS.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
