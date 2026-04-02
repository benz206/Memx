import SwiftUI

// MARK: - ConfidenceBadge

struct ConfidenceBadge: View {
    let score: Float
    var style: BadgeStyle = .pill

    enum BadgeStyle { case pill, icon, ring }

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

        case .ring:
            ScoreRing(score: score, size: 28)
        }
    }
}

// MARK: - EmotionBadge

struct EmotionBadge: View {
    let emotion: Emotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: emotion.icon)
                .font(.system(size: 10))
            Text(emotion.rawValue)
                .font(MS.Font.micro)
        }
        .foregroundStyle(emotionColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(emotionColor.opacity(0.12), in: Capsule())
    }

    private var emotionColor: Color {
        switch emotion {
        case .joy:        return .yellow
        case .nostalgia:  return .orange
        case .excitement: return .red
        case .calm:       return .blue
        case .awe:        return .purple
        case .humor:      return .green
        case .love:       return .pink
        case .surprise:   return .teal
        }
    }
}

// MARK: - MediaTypeBadge

struct MediaTypeBadge: View {
    let type: MSMediaType

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: type.icon)
                .font(.system(size: 10))
            Text(type.rawValue)
                .font(MS.Font.micro)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - BeatAlignedBadge

struct BeatAlignedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform")
                .font(.system(size: 9, weight: .semibold))
            Text("Beat")
                .font(MS.Font.micro)
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.purple.opacity(0.12), in: Capsule())
    }
}

// MARK: - PhaseProgressBadge

struct PhaseProgressBadge: View {
    let phase: AnalysisPhase
    let isActive: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: MS.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 28, height: 28)
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: isComplete ? "checkmark" : phase.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isComplete || isActive ? .white : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(phase.rawValue)
                    .font(MS.Font.caption)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .primary : isComplete ? .secondary : .tertiary)
                if isActive {
                    Text(phase.description)
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    private var circleColor: Color {
        if isActive   { return .accentColor }
        if isComplete { return .green }
        return Color.secondary.opacity(0.2)
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
