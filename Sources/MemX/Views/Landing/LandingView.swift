import SwiftUI

struct LandingView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var appeared = false
    @State private var showPermissionAlert = false
    @State private var showPrivacySettings = false

    var body: some View {
        ZStack {
            MSGradientBackground()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showPrivacySettings = true
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Privacy Settings")
                    .padding([.top, .trailing], MS.Spacing.md)
                }
                Spacer()
            }

            VStack(spacing: 0) {
                Spacer()

                // Hero
                VStack(spacing: MS.Spacing.lg) {
                    appIcon

                    VStack(spacing: MS.Spacing.sm) {
                        Text("MemX")
                            .font(MS.Font.displayLarge)
                            .foregroundStyle(.primary)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)

                        VStack(spacing: 8) {
                            Text("Pick a song. Pick some photos.")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text("We'll turn your still moments into a cinematic montage — animated to every beat drop, buildup, and chorus. Entirely on your Mac.")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                    }
                }

                Spacer().frame(height: MS.Spacing.xxl)

                // Feature cards
                HStack(spacing: MS.Spacing.lg) {
                    ForEach(features, id: \.title) { feature in
                        featureCard(feature)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)

                Spacer().frame(height: MS.Spacing.xxl)

                // CTAs
                VStack(spacing: MS.Spacing.sm) {
                    MSPrimaryButton("Start a New Montage", icon: "sparkles") {
                        handleStart()
                    }
                    .scaleEffect(appeared ? 1 : 0.9)

                    MSSecondaryButton("View Projects", icon: "folder") {
                        appVM.showProjects()
                    }
                }
                .opacity(appeared ? 1 : 0)

                Spacer()

                Text("All analysis, AI scene captioning, motion prompts, and rendering run entirely on your Mac.")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.bottom, MS.Spacing.lg)
                    .opacity(appeared ? 1 : 0)
            }
            .padding(MS.Spacing.xl)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.8).delay(0.1)) {
                appeared = true
            }
        }
        .alert("Photos Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MemX needs access to your Photos library to browse and import memories.")
        }
        .sheet(isPresented: $showPrivacySettings) {
            PrivacySettingsView()
        }
    }

    // MARK: - App Icon

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.accentColor, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)
                .msShadow(.strong)
            Image(systemName: "music.note.list")
                .font(.system(size: 38))
                .foregroundStyle(.white)
        }
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.7)
    }

    // MARK: - Feature Card

    @ViewBuilder
    private func featureCard(_ feature: Feature) -> some View {
        VStack(spacing: MS.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                    .fill(feature.color.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: feature.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(feature.color)
            }
            Text(feature.title)
                .font(MS.Font.heading)
                .foregroundStyle(.primary)
            Text(feature.description)
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 180)
        .msCard()
    }

    // MARK: - Actions

    private func handleStart() {
        Task {
            let status = PhotosLibraryService.shared.authorizationStatus()
            switch status {
            case .authorized, .limited:
                appVM.createProject()
            case .notDetermined:
                let result = await PhotosLibraryService.shared.requestPermission()
                if result == .authorized || result == .limited {
                    appVM.createProject()
                } else {
                    showPermissionAlert = true
                }
            case .restricted, .denied:
                showPermissionAlert = true
            @unknown default:
                appVM.createProject()
            }
        }
    }

    // MARK: - Data

    private struct Feature {
        let icon: String
        let title: String
        let description: String
        let color: Color
    }

    private var features: [Feature] {[
        Feature(icon: "music.note.list", title: "Song First", description: "Pick a track. The beatmap drives every cut, hold, and transition.", color: .purple),
        Feature(icon: "sparkles.rectangle.stack", title: "Motion Prompts", description: "Every photo gets a cinematographer's direction — it breathes, not invents.", color: .orange),
        Feature(icon: "waveform.badge.mic", title: "Beat-Synced Cuts", description: "Drops hit hard. Verses breathe. Breakdowns hold. Fully automatic.", color: .blue),
    ]}
}
