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
                Text("Song")
                    .font(MS.Font.title)
                Text("Every cut, hold, and transition is timed to this track.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
                            .frame(width: 56, height: 56)
                        Image(systemName: "music.note")
                            .font(.system(size: 24))
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
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: song.fileFormatIcon)
                    .font(.system(size: 20))
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
                        .foregroundStyle(section.type.displayColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(section.type.displayColor.opacity(0.1), in: Capsule())
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
            .fill(section.type.displayColor.opacity(0.6 + section.energyAvg * 0.4))
            .frame(width: max(4, width * ratio - 2), height: 32)
            .help("\(section.type.rawValue) (\(Int(section.start))s–\(Int(section.end))s)")
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
        HStack {
            Text("Song imported. Next: pick your photos.")
                .font(MS.Font.body)
                .foregroundStyle(.secondary)

            Spacer()

            MSPrimaryButton("Continue", icon: "arrow.right") {
                workspaceVM.goToStage(.photos)
            }
            .keyboardShortcut(.defaultAction)
        }
        .msCard()
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

    /// Writes go straight through to the project so edits apply immediately,
    /// matching the previous chip-based sheet's behavior.
    private var settings: Binding<MontageSettings> {
        Binding(
            get: { workspaceVM.project.settings },
            set: { workspaceVM.updateSettings($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Montage Settings")
                    .font(MS.Font.title)
                Spacer()
            }
            .padding(.horizontal, MS.Spacing.lg)
            .padding(.top, MS.Spacing.lg)
            .padding(.bottom, MS.Spacing.sm)

            Form {
                Section("Style") {
                    Picker("Vibe", selection: settings.vibe) {
                        ForEach(MontageVibe.allCases, id: \.self) { vibe in
                            Label(vibe.rawValue, systemImage: vibe.icon).tag(vibe)
                        }
                    }
                    Text(settings.wrappedValue.vibe.description)
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)

                    Picker("Focus", selection: settings.focus) {
                        ForEach(MontageFocus.allCases, id: \.self) { focus in
                            Label(focus.rawValue, systemImage: focus.icon).tag(focus)
                        }
                    }
                }

                Section("Output") {
                    Picker("Aspect Ratio", selection: settings.aspectRatio) {
                        ForEach(AspectRatio.allCases, id: \.self) { ratio in
                            Text(ratio.rawValue).tag(ratio)
                        }
                    }

                    Picker("Render Quality", selection: settings.renderQuality) {
                        ForEach(RenderQuality.allCases, id: \.self) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    Text(settings.wrappedValue.renderQuality.description)
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Analysis") {
                    Picker("Scoring Density", selection: settings.scoringDensity) {
                        ForEach(ScoringDensity.allCases, id: \.self) { density in
                            Text(density.rawValue).tag(density)
                        }
                    }
                    Text(settings.wrappedValue.scoringDensity.description)
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(MS.Spacing.md)
        }
        .frame(width: 440, height: 500)
    }
}
