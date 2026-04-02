import SwiftUI

struct MontageSetupView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        ScrollView {
            VStack(spacing: MS.Spacing.lg) {
                header

                // Settings cards in a 2-col layout
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: MS.Spacing.md
                ) {
                    durationCard
                    vibeCard
                    focusCard
                    pacingCard
                    aspectRatioCard
                    musicCard
                }

                // Generate CTA
                generateCard
            }
            .padding(MS.Spacing.xl)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Montage Setup")
                    .font(MS.Font.title)
                Text("Configure how your montage is assembled.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspaceVM.assets.isEmpty {
                MSBadge(text: "No media imported", color: .orange)
            } else {
                MSBadge(text: "\(workspaceVM.totalAssetCount) assets ready", color: .green)
            }
        }
    }

    // MARK: - Setting Cards

    private var durationCard: some View {
        settingCard(title: "Target Duration", icon: "clock.fill") {
            VStack(spacing: MS.Spacing.sm) {
                ForEach(TargetDuration.allCases, id: \.self) { dur in
                    selectionRow(
                        title: dur.label,
                        subtitle: "\(Int(dur.seconds))s",
                        isSelected: workspaceVM.project.settings.targetDuration == dur
                    ) {
                        var s = workspaceVM.project.settings
                        s.targetDuration = dur
                        workspaceVM.updateSettings(s)
                    }
                }
            }
        }
    }

    private var vibeCard: some View {
        settingCard(title: "Vibe", icon: "sparkles") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MS.Spacing.sm) {
                ForEach(MontageVibe.allCases, id: \.self) { vibe in
                    vibeChip(vibe)
                }
            }
        }
    }

    private var focusCard: some View {
        settingCard(title: "Focus", icon: "viewfinder") {
            VStack(spacing: MS.Spacing.sm) {
                ForEach(MontageFocus.allCases, id: \.self) { focus in
                    selectionRow(
                        title: focus.rawValue,
                        icon: focus.icon,
                        isSelected: workspaceVM.project.settings.focus == focus
                    ) {
                        var s = workspaceVM.project.settings
                        s.focus = focus
                        workspaceVM.updateSettings(s)
                    }
                }
            }
        }
    }

    private var pacingCard: some View {
        settingCard(title: "Pacing", icon: "speedometer") {
            VStack(spacing: MS.Spacing.sm) {
                ForEach(MontagePacing.allCases, id: \.self) { pacing in
                    selectionRow(
                        title: pacing.rawValue,
                        subtitle: "\(Int(pacing.beatsPerMinute.lowerBound))–\(Int(pacing.beatsPerMinute.upperBound)) BPM",
                        isSelected: workspaceVM.project.settings.pacing == pacing
                    ) {
                        var s = workspaceVM.project.settings
                        s.pacing = pacing
                        workspaceVM.updateSettings(s)
                    }
                }
            }
        }
    }

    private var aspectRatioCard: some View {
        settingCard(title: "Aspect Ratio", icon: "aspectratio.fill") {
            HStack(spacing: MS.Spacing.sm) {
                ForEach(AspectRatio.allCases, id: \.self) { ratio in
                    ratioChip(ratio)
                }
            }
        }
    }

    private var musicCard: some View {
        settingCard(title: "Music Genre", icon: "music.note") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MS.Spacing.sm) {
                ForEach(MusicGenre.allCases, id: \.self) { genre in
                    selectionRow(
                        title: genre.rawValue,
                        icon: genre.icon,
                        isSelected: workspaceVM.project.settings.musicPreference == genre
                    ) {
                        var s = workspaceVM.project.settings
                        s.musicPreference = genre
                        workspaceVM.updateSettings(s)
                    }
                }
            }
        }
    }

    // MARK: - Generate Card

    private var generateCard: some View {
        VStack(spacing: MS.Spacing.md) {
            VStack(spacing: 6) {
                Text("Ready to Generate")
                    .font(MS.Font.heading)
                Text("The AI pipeline will analyze your \(workspaceVM.totalAssetCount) assets and build a storyboard based on your settings above.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Summary row
            HStack(spacing: MS.Spacing.md) {
                summaryChip(icon: "clock", value: workspaceVM.project.settings.targetDuration.label)
                summaryChip(icon: "sparkles", value: workspaceVM.project.settings.vibe.rawValue)
                summaryChip(icon: "speedometer", value: workspaceVM.project.settings.pacing.rawValue)
                summaryChip(icon: "aspectratio", value: workspaceVM.project.settings.aspectRatio.rawValue)
                summaryChip(icon: "music.note", value: workspaceVM.project.settings.musicPreference.rawValue)
            }

            MSPrimaryButton(
                workspaceVM.isAnalyzing ? "Generating..." : "Generate Montage Plan",
                icon: workspaceVM.isAnalyzing ? nil : "sparkles",
                isLoading: workspaceVM.isAnalyzing
            ) {
                Task {
                    await workspaceVM.runAnalysis()
                }
            }
            .disabled(!workspaceVM.canAnalyze)

            if workspaceVM.assets.isEmpty {
                Text("Import some media first to generate a plan.")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .msCard(padding: MS.Spacing.xl)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MS.Spacing.md) {
            Label(title, systemImage: icon)
                .font(MS.Font.heading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }

    @ViewBuilder
    private func selectionRow(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: MS.Spacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? .accentColor : .secondary)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(MS.Font.body)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    if let sub = subtitle {
                        Text(sub)
                            .font(MS.Font.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.accentColor)
                }
            }
            .padding(MS.Spacing.sm)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func vibeChip(_ vibe: MontageVibe) -> some View {
        let isSelected = workspaceVM.project.settings.vibe == vibe
        Button {
            var s = workspaceVM.project.settings
            s.vibe = vibe
            workspaceVM.updateSettings(s)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: vibe.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? .accentColor : .secondary)
                Text(vibe.rawValue)
                    .font(MS.Font.micro)
                    .foregroundStyle(isSelected ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(vibe.description)
    }

    @ViewBuilder
    private func ratioChip(_ ratio: AspectRatio) -> some View {
        let isSelected = workspaceVM.project.settings.aspectRatio == ratio
        Button {
            var s = workspaceVM.project.settings
            s.aspectRatio = ratio
            workspaceVM.updateSettings(s)
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    .frame(
                        width: ratio == .portrait ? 18 : ratio == .square ? 22 : 32,
                        height: ratio == .portrait ? 32 : ratio == .square ? 22 : 18
                    )
                Text(ratio.rawValue)
                    .font(MS.Font.micro)
                    .foregroundStyle(isSelected ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MS.Spacing.sm)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func summaryChip(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(MS.Font.micro)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, MS.Spacing.sm)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}
