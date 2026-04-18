import SwiftUI

struct PrivacySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var allowUploads: Bool = PrivacyPreferences.allowAnthropicUploads
    @State private var apiKey: String = KeychainHelper.anthropicAPIKey() ?? ""
    @State private var apiKeyError: String? = nil
    @State private var showKeySaved = false

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

            VStack(alignment: .leading, spacing: MS.Spacing.md) {
                MSSectionHeader(title: "Anthropic Claude", subtitle: "Optional AI motion prompt generation")

                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    Toggle("Enable Anthropic motion prompts", isOn: Binding(
                        get: { PrivacyPreferences.allowAnthropicUploads },
                        set: { PrivacyPreferences.allowAnthropicUploads = $0; allowUploads = $0 }
                    ))
                    .font(MS.Font.body)

                    if allowUploads {
                        VStack(alignment: .leading, spacing: MS.Spacing.xs) {
                            Text("When enabled, MemX sends:")
                                .font(MS.Font.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                disclosureRow(icon: "photo", text: "Thumbnails ≤512 px (no EXIF, no location)")
                                disclosureRow(icon: "person.slash", text: "No personal identifiers")
                                disclosureRow(icon: "location.slash", text: "No location data")
                                disclosureRow(icon: "arrow.triangle.2.circlepath", text: "Prompts generated per clip, not stored by MemX")
                            }
                        }
                        .padding(MS.Spacing.sm)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
                    }
                }
                .msCard()

                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Anthropic API Key")

                    HStack(spacing: MS.Spacing.sm) {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(MS.Font.mono)

                        MSPrimaryButton("Save", icon: "checkmark") {
                            saveKey()
                        }
                        .disabled(apiKey.isEmpty)

                        if !apiKey.isEmpty {
                            MSSecondaryButton("Clear", isDestructive: true) {
                                clearKey()
                            }
                        }
                    }

                    if let err = apiKeyError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                            Text(err).font(MS.Font.caption).foregroundStyle(.red)
                        }
                    }

                    if showKeySaved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("API key saved to Keychain.").font(MS.Font.caption).foregroundStyle(.secondary)
                        }
                    }

                    Text("Your key is stored only in your Mac's Keychain and never transmitted.")
                        .font(MS.Font.micro)
                        .foregroundStyle(.tertiary)
                }
                .msCard()
            }

            MSSecondaryButton("Done") { dismiss() }
        }
        .padding(MS.Spacing.xl)
        .frame(width: 460)
    }

    private func disclosureRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        apiKeyError = nil
        showKeySaved = false
        do {
            try KeychainHelper.setAnthropicAPIKey(apiKey.isEmpty ? nil : apiKey)
            showKeySaved = true
        } catch {
            apiKeyError = error.localizedDescription
        }
    }

    private func clearKey() {
        apiKey = ""
        apiKeyError = nil
        showKeySaved = false
        try? KeychainHelper.setAnthropicAPIKey(nil)
    }
}
