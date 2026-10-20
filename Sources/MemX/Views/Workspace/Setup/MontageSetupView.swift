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
            VStack(alignment: .leading, spacing: MS.Spacing.lg) {
                MSPageHeader(
                    title: "Song",
                    subtitle: "Every cut, hold, and transition is timed to this track."
                ) {
                    if workspaceVM.hasSong {
                        MSSecondaryButton("Replace Song", icon: "arrow.triangle.2.circlepath") {
                            showFilePicker = true
                        }
                    }
                }

                if let song = workspaceVM.songTrack {
                    songCard(song)
                } else {
                    dropZone
                }

                if workspaceVM.hasBeatmap, let beatmap = workspaceVM.beatmap {
                    beatmapStats(beatmap)
                    structureCard(beatmap)
                }

                settingsCard

                if workspaceVM.hasSong {
                    continueRow
                }
            }
            .msPage(maxWidth: 880)
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
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(workspaceVM)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isTargeted ? MSColor.inkBright : MSColor.inkMuted)
                .frame(width: 40, height: 40)
                .background(MSColor.surface2, in: RoundedRectangle(cornerRadius: MS.Radius.md + 2, style: .continuous))
            Text("Drop a song here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MSColor.inkBright)
            Text("MP3, M4A, WAV, AAC or AIFF")
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkMuted)
            MSSecondaryButton("Choose File…", icon: "folder") {
                showFilePicker = true
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(
            (isTargeted ? MSColor.surface2 : MSColor.surface),
            in: RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MS.Radius.lg, style: .continuous)
                .strokeBorder(isTargeted ? MSColor.inkMuted : MSColor.lineStrong,
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
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

    // MARK: - Song Card (after import)

    private func songCard(_ song: SongTrack) -> some View {
        HStack(spacing: 12) {
            Image(systemName: song.fileFormatIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MSColor.inkMuted)
                .frame(width: 40, height: 40)
                .background(MSColor.surface2, in: RoundedRectangle(cornerRadius: MS.Radius.md + 2, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MSColor.inkBright)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkMuted)
            }

            Spacer()

            HStack(spacing: 6) {
                if song.durationSeconds > 0 {
                    MSBadge(text: song.durationString, size: .small)
                }
                MSBadge(text: song.fileFormat.uppercased(), size: .small)
            }
        }
        .msCard(padding: 14)
    }

    // MARK: - Beatmap Card

    private func beatmapStats(_ beatmap: Beatmap) -> some View {
        MSStatStrip(stats: [
            MSStat(label: "Tempo", value: "\(Int(beatmap.bpm.rounded()))", sub: "BPM"),
            MSStat(label: "Length", value: Self.clock(beatmap.durationSeconds), sub: "\(beatmap.beats.count) beats"),
            MSStat(label: "Sections", value: "\(beatmap.sections.count)",
                   sub: "\(beatmap.sections.filter { $0.type == .chorus || $0.type == .drop }.count) chorus / drop"),
            MSStat(label: "Hooks", value: "\(beatmap.hooks.count)", sub: "repeating moments"),
            MSStat(label: "Drops", value: "\(beatmap.drops.count)", sub: "\(beatmap.vocalPeaks.count) vocal peaks"),
        ])
    }

    private func structureCard(_ beatmap: Beatmap) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MSSectionHeader(title: "Structure", subtitle: "Sections detected from energy and onsets.")

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(beatmap.sections) { section in
                        sectionStrip(section, totalDuration: beatmap.durationSeconds, width: geo.size.width)
                    }
                }
            }
            .frame(height: 28)

            HStack {
                Text("0:00")
                Spacer()
                Text(Self.clock(beatmap.durationSeconds / 2))
                Spacer()
                Text(Self.clock(beatmap.durationSeconds))
            }
            .font(MS.Font.mono)
            .foregroundStyle(MSColor.inkFaint)

            let types = beatmap.sections.map(\.type).reduce(into: [SectionType]()) { seen, t in
                if !seen.contains(t) { seen.append(t) }
            }
            HStack(spacing: 14) {
                ForEach(types, id: \.self) { type in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(type.displayColor).frame(width: 8, height: 8)
                        Text(type.rawValue)
                            .font(MS.Font.caption)
                            .foregroundStyle(MSColor.inkMuted)
                    }
                }
            }
        }
        .msCard()
    }

    private func sectionStrip(_ section: BeatSection, totalDuration: Double, width: CGFloat) -> some View {
        let ratio = CGFloat(section.duration / totalDuration)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(section.type.displayColor.opacity(0.35 + section.energyAvg * 0.5))
            .frame(width: max(4, width * ratio - 2), height: 28)
            .help("\(section.type.rawValue) (\(Self.clock(section.start))–\(Self.clock(section.end)))")
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Settings Card

    private var settingsCard: some View {
        let settings = workspaceVM.project.settings
        return VStack(alignment: .leading, spacing: 0) {
            MSPanelHeader(title: "Montage Settings") {
                MSSecondaryButton("Edit", icon: "slider.horizontal.3", size: .small) {
                    showSettings = true
                }
            }

            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    settingRow(title: "Vibe", value: settings.vibe.rawValue, icon: settings.vibe.icon)
                    settingRow(title: "Focus", value: settings.focus.rawValue, icon: settings.focus.icon)
                }
                MSDivider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    settingRow(title: "Aspect Ratio", value: settings.aspectRatio.rawValue, icon: "aspectratio")
                    settingRow(title: "Render", value: settings.renderQuality.rawValue, icon: settings.renderQuality.icon)
                }
            }
        }
        .msCard(padding: 0)
    }

    // MARK: - Continue Card

    private var continueRow: some View {
        HStack(spacing: MS.Spacing.sm) {
            Spacer()
            Text("Next: pick your photos")
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkMuted)
            MSPrimaryButton("Continue", icon: "arrow.right") {
                workspaceVM.goToStage(.photos)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func settingRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(MSColor.inkFaint)
                .frame(width: 18)
            Text(title)
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkMuted)
            Spacer()
            Text(value)
                .font(MS.Font.body.weight(.medium))
                .foregroundStyle(MSColor.inkBright)
        }
        .padding(.horizontal, MS.Spacing.md)
        .frame(height: 40)
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
                    .buttonStyle(.ms(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(MS.Spacing.md)
        }
        .frame(width: 440, height: 500)
    }
}
