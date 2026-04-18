import SwiftUI

struct PrivacySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.lg) {
            HStack {
                Text("Privacy Settings")
                    .font(MS.Font.title)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                HStack(spacing: MS.Spacing.sm) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All AI runs on-device.")
                            .font(MS.Font.heading)
                        Text("No data ever leaves your Mac.")
                            .font(MS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    privacyRow(
                        icon: "brain",
                        title: "Scene captions",
                        detail: "Apple Foundation Models (SystemLanguageModel) — on-device only."
                    )
                    privacyRow(
                        icon: "sparkles",
                        title: "Motion directions",
                        detail: "Apple Foundation Models (SystemLanguageModel) — on-device only."
                    )
                    privacyRow(
                        icon: "eye",
                        title: "Photo scoring",
                        detail: "Apple Vision framework — on-device only."
                    )
                    privacyRow(
                        icon: "music.note",
                        title: "Audio analysis",
                        detail: "AVFoundation + vDSP — on-device only."
                    )
                }
            }
            .msCard()

            MSSecondaryButton("Done") { dismiss() }
        }
        .padding(MS.Spacing.xl)
        .frame(width: 460)
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: MS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MS.Font.caption)
                    .fontWeight(.medium)
                Text(detail)
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
