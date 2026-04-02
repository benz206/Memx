import SwiftUI

struct LandingView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var appeared = false
    @State private var showPermissionAlert = false

    var body: some View {
        ZStack {
            MSGradientBackground()

            VStack(spacing: 0) {
                Spacer()

                // Hero
                VStack(spacing: MS.Spacing.lg) {
                    appIcon

                    VStack(spacing: MS.Spacing.sm) {
                        Text("Memory Stitcher")
                            .font(MS.Font.displayLarge)
                            .foregroundStyle(.primary)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)

                        Text("Turn your Apple Photos into a cinematic memory montage — automatically, privately, on-device.")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 12)
                    }
                }

                Spacer().frame(height: MS.Spacing.xxl)

                // Features row
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

                    Button("View Projects") {
                        appVM.showProjects()
                    }
                    .buttonStyle(.plain)
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)

                Spacer()

                // Footer
                Text("All processing happens on your Mac. Your photos never leave your device.")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
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
            Button("Continue Anyway") { appVM.createProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Memory Stitcher needs access to your Photos library to import and analyze your memories.")
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

            Image(systemName: "film.stack.fill")
                .font(.system(size: 40))
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
        Feature(icon: "photo.stack.fill", title: "Smart Import", description: "Browse albums, pick photos & videos — all from your Apple Photos library.", color: .blue),
        Feature(icon: "cpu.fill", title: "On-Device AI", description: "Scene detection, emotion scoring, and event clustering run locally.", color: .purple),
        Feature(icon: "film.stack.fill", title: "Storyboard", description: "A curated, ordered sequence with transitions, beats, and soundtrack.", color: .orange),
    ]}
}
