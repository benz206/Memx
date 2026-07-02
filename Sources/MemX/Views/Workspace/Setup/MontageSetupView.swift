import SwiftUI
import UniformTypeIdentifiers

// MARK: - SongImportView
// Step 1 of the workspace: import a song file. Everything else flows from the song.

struct SongImportView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @State private var isTargeted = false
    @State private var showFilePicker = false
    @State private var showSettings = false

    private let supportedTypes: [UTType] = [
        .mp3, .mpeg4Audio, .wav, .aiff,
        UTType(filenameExtension: "aac") ?? .audio
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: MS.Spacing.lg) {
                header

                if let song = workspaceVM.songTrack {
                    songCard(song)
                } else {
                    dropZone
                }

                if workspaceVM.hasBeatmap, let beatmap = workspaceVM.beatmap {
                    beatmapCard(beatmap)
                }

                settingsCard

                if workspaceVM.hasSong {
                    continueCard
                }
            }
            .padding(MS.Spacing.xl)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await workspaceVM.importSong(from: url) }
                }
            case .failure:
                break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick a Song")
                    .font(MS.Font.title)
                Text("The song is the director. Every cut, hold, and transition flows from the music.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MSBadge(text: "Step 1", color: .accentColor)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: MS.Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                    )
                    .background(
                        isTargeted ? Color.accentColor.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous)
                    )
                    .animation(.easeOut(duration: 0.2), value: isTargeted)

                VStack(spacing: MS.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                            .frame(width: 72, height: 72)
                        Image(systemName: "music.note")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(spacing: 6) {
                        Text("Drop a song here")
                            .font(MS.Font.heading)
                        Text("Supports MP3, M4A, WAV, AAC, AIFF")
                            .font(MS.Font.caption)
                            .foregroundStyle(.secondary)
                    }

                    MSSecondaryButton("Choose File", icon: "folder") {
                        showFilePicker = true
                    }
                }
                .padding(MS.Spacing.xxl)
            }
            .frame(minHeight: 220)
            .onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                    guard let url else { return }
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.copyItem(at: url, to: dest)
                    Task { await workspaceVM.importSong(from: dest) }
                }
                return true
            }
        }
        .msCard()
    }

    // MARK: - Song Card (after import)

    private func songCard(_ song: SongTrack) -> some View {
        HStack(spacing: MS.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.3), .purple.opacity(0.2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                Image(systemName: song.fileFormatIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayTitle)
                    .font(MS.Font.heading)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: MS.Spacing.sm) {
                    if song.durationSeconds > 0 {
                        MSBadge(text: song.durationString, size: .small)
                    }
                    if let bpm = song.bpm {
                        MSBadge(text: "\(Int(bpm)) BPM", color: .purple, size: .small)
                    }
                    MSBadge(text: song.fileFormat.uppercased(), size: .small)
                }
            }

            Spacer()

            MSSecondaryButton("Change", icon: "arrow.triangle.2.circlepath") {
                showFilePicker = true
            }
        }
        .msCard()
    }

    // MARK: - Beatmap Card

    private func beatmapCard(_ beatmap: Beatmap) -> some View {
        VStack(alignment: .leading, spacing: MS.Spacing.md) {
            MSSectionHeader(title: "Beatmap", subtitle: "\(beatmap.beats.count) beats · \(beatmap.sections.count) sections · \(beatmap.drops.count) drops")

            // Section strips
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(beatmap.sections) { section in
                        sectionStrip(section, totalDuration: beatmap.durationSeconds, width: geo.size.width)
                    }
                }
            }
            .frame(height: 32)

            // Section legend
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MS.Spacing.sm) {
                    ForEach(beatmap.sections) { section in
                        HStack(spacing: 4) {
                            Image(systemName: section.type.icon)
                                .font(.system(size: 9))
                            Text(section.type.rawValue)
                                .font(MS.Font.micro)
                        }
                        .foregroundStyle(sectionColor(section.type))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(sectionColor(section.type).opacity(0.1), in: Capsule())
                    }
                }
            }

            // Stats row
            HStack(spacing: MS.Spacing.lg) {
                statChip(icon: "bolt.fill", label: "Drops", value: "\(beatmap.drops.count)", color: .red)
                statChip(icon: "waveform", label: "Beats", value: "\(beatmap.beats.count)", color: .blue)
                statChip(icon: "mic.fill", label: "Vocal peaks", value: "\(beatmap.vocalPeaks.count)", color: .purple)
            }
        }
        .msCard()
    }

    private func sectionStrip(_ section: BeatSection, totalDuration: Double, width: CGFloat) -> some View {
        let ratio = CGFloat(section.duration / totalDuration)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(sectionColor(section.type).opacity(0.6 + section.energyAvg * 0.4))
            .frame(width: max(4, width * ratio - 2), height: 32)
            .help("\(section.type.rawValue) (\(Int(section.start))s–\(Int(section.end))s)")
    }

    private func sectionColor(_ type: SectionType) -> Color {
        switch type {
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

    private func statChip(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text("\(value) \(label)").font(MS.Font.micro).foregroundStyle(.secondary)
        }
    }

    // MARK: - Settings Card

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.md) {
            MSSectionHeader(title: "Montage Settings")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MS.Spacing.sm) {
                settingRow(title: "Vibe", value: workspaceVM.project.settings.vibe.rawValue, icon: workspaceVM.project.settings.vibe.icon)
                settingRow(title: "Focus", value: workspaceVM.project.settings.focus.rawValue, icon: workspaceVM.project.settings.focus.icon)
                settingRow(title: "Aspect Ratio", value: workspaceVM.project.settings.aspectRatio.rawValue, icon: "aspectratio.fill")
                settingRow(title: "Render", value: workspaceVM.project.settings.renderQuality.rawValue, icon: workspaceVM.project.settings.renderQuality.icon)
            }

            MSSecondaryButton("Edit Settings", icon: "slider.horizontal.3") {
                showSettings = true
            }
        }
        .msCard()
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(workspaceVM)
        }
    }

    // MARK: - Continue Card

    private var continueCard: some View {
        VStack(spacing: MS.Spacing.sm) {
            Text("Song imported. Next: pick your photos.")
                .font(MS.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            MSPrimaryButton("Choose Photos", icon: "photo.stack.fill") {
                workspaceVM.goToStage(.photos)
            }
        }
        .frame(maxWidth: .infinity)
        .msCard(padding: MS.Spacing.lg)
    }

    // MARK: - Helpers

    private func settingRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(MS.Font.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(MS.Spacing.sm)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous))
    }
}

// MARK: - SettingsSheet

struct SettingsSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: MS.Spacing.lg) {
            Text("Montage Settings")
                .font(MS.Font.title)

            settingCard(title: "Vibe", icon: "sparkles") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MS.Spacing.sm) {
                    ForEach(MontageVibe.allCases, id: \.self) { vibe in
                        vibeChip(vibe)
                    }
                }
            }

            settingCard(title: "Focus", icon: "viewfinder") {
                HStack(spacing: MS.Spacing.sm) {
                    ForEach(MontageFocus.allCases, id: \.self) { focus in
                        selectionChip(
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

            settingCard(title: "Render Quality", icon: "cpu") {
                VStack(spacing: MS.Spacing.sm) {
                    ForEach(RenderQuality.allCases, id: \.self) { quality in
                        Button {
                            var s = workspaceVM.project.settings
                            s.renderQuality = quality
                            workspaceVM.updateSettings(s)
                        } label: {
                            HStack(spacing: MS.Spacing.sm) {
                                Image(systemName: quality.icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(workspaceVM.project.settings.renderQuality == quality ? Color.accentColor : Color.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quality.rawValue)
                                        .font(MS.Font.caption)
                                        .foregroundStyle(workspaceVM.project.settings.renderQuality == quality ? .primary : .secondary)
                                    Text(quality.description)
                                        .font(MS.Font.micro)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if workspaceVM.project.settings.renderQuality == quality {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(MS.Spacing.sm)
                            .background(
                                workspaceVM.project.settings.renderQuality == quality ? Color.accentColor.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            settingCard(title: "Scoring Density", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    HStack(spacing: MS.Spacing.xs) {
                        ForEach(ScoringDensity.allCases, id: \.self) { density in
                            densityChip(density)
                        }
                    }
                    Text("Denser scoring picks stronger moments but takes longer. Balanced is recommended.")
                        .font(MS.Font.micro)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(workspaceVM.project.settings.scoringDensity.description)
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                }
            }

            MSSecondaryButton("Done") { dismiss() }
        }
        .padding(MS.Spacing.xl)
        .frame(width: 420)
    }

    @ViewBuilder
    private func settingCard<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            Label(title, systemImage: icon).font(MS.Font.heading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }

    private func vibeChip(_ vibe: MontageVibe) -> some View {
        let isSelected = workspaceVM.project.settings.vibe == vibe
        return Button {
            var s = workspaceVM.project.settings
            s.vibe = vibe
            workspaceVM.updateSettings(s)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: vibe.icon).font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(vibe.rawValue).font(MS.Font.micro)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
            )
        }
        .buttonStyle(.plain)
    }

    private func selectionChip(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title).font(MS.Font.micro)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MS.Spacing.sm)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func densityChip(_ density: ScoringDensity) -> some View {
        let isSelected = workspaceVM.project.settings.scoringDensity == density
        return Button {
            var s = workspaceVM.project.settings
            s.scoringDensity = density
            workspaceVM.updateSettings(s)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: density.icon).font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(density.rawValue).font(MS.Font.micro)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MS.Spacing.sm)
            .padding(.horizontal, 2)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
