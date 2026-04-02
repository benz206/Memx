import SwiftUI

struct StoryboardView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        Group {
            if let plan = workspaceVM.montagePlan {
                StoryboardContentView(plan: plan)
            } else if workspaceVM.isGeneratingPlan {
                generatingView
            } else {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No Storyboard Yet",
                    subtitle: "Run analysis on your media to generate a montage storyboard.",
                    action: ("Go to Analysis", { workspaceVM.selectedTab = .analysis })
                )
            }
        }
    }

    private var generatingView: some View {
        VStack(spacing: MS.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
            Text("Building storyboard...")
                .font(MS.Font.heading)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - StoryboardContentView

struct StoryboardContentView: View {
    let plan: MontagePlan
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @State private var selectedItem: MontageSequenceItem? = nil
    @State private var showExportSheet = false

    var body: some View {
        HStack(spacing: 0) {
            // Sequence list
            sequenceList
                .frame(minWidth: 320, maxWidth: 380)

            MSDivider().frame(width: 1).frame(maxHeight: .infinity)

            // Detail + summary panel
            VStack(spacing: 0) {
                planSummaryHeader
                MSDivider()
                if let item = selectedItem {
                    itemDetailPanel(item)
                } else {
                    moodArcPanel
                }
            }
        }
    }

    // MARK: - Sequence List

    private var sequenceList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sequence")
                        .font(MS.Font.heading)
                    Text("\(plan.sequence.count) clips · \(formatDuration(plan.totalDuration))")
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await workspaceVM.generatePlan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Re-generate storyboard")
            }
            .padding(MS.Spacing.md)

            MSDivider()

            List(selection: $selectedItem) {
                ForEach(plan.sequence) { item in
                    StoryboardSequenceRow(
                        item: item,
                        position: item.position + 1,
                        isSelected: selectedItem?.id == item.id
                    )
                    .tag(item)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            workspaceVM.removeSequenceItem(item)
                            if selectedItem?.id == item.id { selectedItem = nil }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .onMove { src, dst in
                    workspaceVM.moveSequenceItem(from: src, to: dst)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Plan Summary Header

    private var planSummaryHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MS.Spacing.lg) {
                summaryItem(icon: "clock", label: "Duration", value: formatDuration(plan.totalDuration))
                summaryItem(icon: "film.stack", label: "Clips", value: "\(plan.sequence.count)")
                summaryItem(icon: "sparkles", label: "Vibe", value: plan.settings.vibe.rawValue)
                summaryItem(icon: "speedometer", label: "Pacing", value: plan.settings.pacing.rawValue)
                summaryItem(icon: "music.note", label: "Genre", value: plan.settings.musicPreference.rawValue)
                summaryItem(icon: "aspectratio", label: "Ratio", value: plan.settings.aspectRatio.rawValue)

                Spacer()

                MSSecondaryButton("Export Plan", icon: "square.and.arrow.up") {
                    showExportSheet = true
                }
                .padding(.trailing, MS.Spacing.md)
            }
            .padding(.horizontal, MS.Spacing.md)
            .padding(.vertical, MS.Spacing.sm)
        }
        .background(.bar)
        .sheet(isPresented: $showExportSheet) {
            ExportPlanSheet(plan: plan)
        }
    }

    // MARK: - Item Detail Panel

    @ViewBuilder
    private func itemDetailPanel(_ item: MontageSequenceItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.md) {
                // Clip header
                HStack {
                    Text("Clip \(item.position + 1)")
                        .font(MS.Font.title)
                    Spacer()
                    ConfidenceBadge(score: item.confidenceScore)
                }

                // Thumbnail
                if let asset = workspaceVM.assets.first(where: { $0.id == item.assetID }) {
                    AssetThumbnailView(asset: asset, size: 200, cornerRadius: MS.Radius.md, isSelected: false, showOverlay: true)
                        .frame(maxWidth: .infinity)
                }

                // Clip timing
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Timing")
                    MSStatRow(label: "Clip Start", value: formatTimestamp(item.clipStart), icon: "arrow.right.to.line")
                    MSStatRow(label: "Clip End", value: formatTimestamp(item.clipEnd), icon: "arrow.left.to.line")
                    MSStatRow(label: "Duration", value: formatDuration(item.clipDuration), icon: "timer")
                    MSStatRow(label: "Timeline Start", value: formatTimestamp(item.estimatedFinalStart), icon: "play.fill")
                    MSStatRow(label: "Timeline End", value: formatTimestamp(item.estimatedFinalEnd), icon: "stop.fill")
                }
                .msCard()

                // Transition picker
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Transition")
                    HStack {
                        ForEach(TransitionType.allCases.prefix(5), id: \.self) { trans in
                            transitionChip(trans, for: item)
                        }
                    }
                }
                .msCard()

                // AI reasoning
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Why Selected")
                    Text(item.selectionReason)
                        .font(MS.Font.body)
                        .foregroundStyle(.secondary)

                    HStack(spacing: MS.Spacing.xs) {
                        MSBadge(text: item.eventLabel, color: .accentColor, size: .small)
                        if item.beatAligned { BeatAlignedBadge() }
                    }
                }
                .msCard()
            }
            .padding(MS.Spacing.md)
        }
    }

    // MARK: - Mood Arc Panel

    private var moodArcPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.lg) {
                MoodArcChart(points: plan.moodArc)
                    .frame(height: 160)
                    .msCard()

                SoundtrackPanel(songs: plan.suggestedSongs)

                // Export render placeholder
                renderPipelinePlaceholder
            }
            .padding(MS.Spacing.md)
        }
    }

    // MARK: - Render Pipeline Placeholder

    private var renderPipelinePlaceholder: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(
                title: "Export / Render Pipeline",
                subtitle: "Future: AVFoundation composition + on-device rendering"
            )

            VStack(spacing: MS.Spacing.sm) {
                ForEach(exportSteps, id: \.0) { step in
                    HStack(spacing: MS.Spacing.sm) {
                        Image(systemName: step.1)
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.0)
                                .font(MS.Font.caption)
                                .foregroundStyle(.secondary)
                            Text(step.2)
                                .font(MS.Font.micro)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        MSBadge(text: "TODO", color: .orange, size: .small)
                    }
                }
            }

            MSSecondaryButton("Export as Edit Decision List (.edl)", icon: "doc.text") {}
                .disabled(true)
                .opacity(0.5)
        }
        .msCard()
    }

    private var exportSteps: [(String, String, String)] {[
        ("AVComposition Assembly", "film.fill", "Stitch clips using AVMutableComposition"),
        ("Audio Mix", "waveform", "Overlay soundtrack via AVAudioMix"),
        ("Transition Rendering", "sparkles", "Apply Core Image filters for transitions"),
        ("Export Session", "arrow.down.circle", "AVAssetExportSession → H.264 / HEVC"),
    ]}

    // MARK: - Helpers

    private func summaryItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(MS.Font.caption)
                .fontWeight(.medium)
            Text(label)
                .font(MS.Font.micro)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }

    private func transitionChip(_ trans: TransitionType, for item: MontageSequenceItem) -> some View {
        let isSelected = item.transitionType == trans
        return Button {
            workspaceVM.updateTransition(for: item, to: trans)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: trans.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(trans.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(6)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        String(format: "%.2fs", t)
    }
}

// MARK: - StoryboardSequenceRow

struct StoryboardSequenceRow: View {
    let item: MontageSequenceItem
    let position: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: MS.Spacing.sm) {
            // Position
            Text("\(position)")
                .font(MS.Font.mono)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
                .frame(width: 52, height: 36)
                .overlay(
                    Image(systemName: "photo.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor.opacity(0.5))
                )

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.eventLabel)
                        .font(MS.Font.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if item.beatAligned { BeatAlignedBadge() }
                }
                HStack(spacing: MS.Spacing.xs) {
                    Text(String(format: "%.1fs", item.clipDuration))
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 2) {
                        Image(systemName: item.transitionType.icon)
                            .font(.system(size: 9))
                        Text(item.transitionType.rawValue)
                            .font(MS.Font.micro)
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            ConfidenceBadge(score: item.confidenceScore, style: .icon)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - MoodArcChart

struct MoodArcChart: View {
    let points: [MoodPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(title: "Mood Arc", subtitle: "Valence (joy) and energy through the timeline")

            if points.isEmpty {
                Text("No mood data")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    ZStack {
                        // Energy line (orange)
                        Path { path in
                            for (i, point) in points.enumerated() {
                                let x = point.position * geo.size.width
                                let y = (1 - point.energy) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else       { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        // Valence line (blue)
                        Path { path in
                            for (i, point) in points.enumerated() {
                                let x = point.position * geo.size.width
                                let y = (1 - point.valence) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else       { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        // Labels
                        ForEach(points, id: \.position) { point in
                            let x = point.position * geo.size.width
                            let y = (1 - point.valence) * geo.size.height
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .position(x: x, y: y)
                        }
                    }
                }
                .frame(height: 80)

                // Legend
                HStack(spacing: MS.Spacing.lg) {
                    legendItem(color: .accentColor, label: "Valence")
                    legendItem(color: .orange, label: "Energy")
                    Spacer()
                    ForEach(points.prefix(4), id: \.position) { p in
                        Text(p.label)
                            .font(MS.Font.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 16, height: 2)
            Text(label).font(MS.Font.micro).foregroundStyle(.secondary)
        }
    }
}

// MARK: - SoundtrackPanel

struct SoundtrackPanel: View {
    let songs: [SongSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(title: "Suggested Soundtrack", subtitle: "Matched to mood arc and vibe")

            ForEach(songs.prefix(3)) { song in
                HStack(spacing: MS.Spacing.md) {
                    // Album art placeholder
                    RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.3), .purple.opacity(0.2)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(MS.Font.caption)
                            .fontWeight(.semibold)
                        Text(song.artist)
                            .font(MS.Font.micro)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        ConfidenceBadge(score: song.vibeMatch)
                        Text("\(Int(song.bpm)) BPM")
                            .font(MS.Font.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(MS.Spacing.sm)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
            }
        }
        .msCard()
    }
}

// MARK: - ExportPlanSheet

struct ExportPlanSheet: View {
    let plan: MontagePlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: MS.Spacing.lg) {
            Text("Export Montage Plan")
                .font(MS.Font.title)

            VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                exportOption(icon: "doc.text", title: "Edit Decision List (.edl)", subtitle: "Import directly into Premiere, DaVinci, or Final Cut", available: false)
                exportOption(icon: "doc.badge.arrow.up", title: "JSON Storyboard", subtitle: "Machine-readable plan for custom pipelines", available: true)
                exportOption(icon: "doc.richtext", title: "PDF Shot List", subtitle: "Printable shot-by-shot breakdown", available: false)
                exportOption(icon: "film.fill", title: "Rendered Video (AVFoundation)", subtitle: "On-device render pipeline — coming soon", available: false)
            }

            MSSecondaryButton("Close") { dismiss() }
        }
        .padding(MS.Spacing.xl)
        .frame(width: 420)
    }

    private func exportOption(icon: String, title: String, subtitle: String, available: Bool) -> some View {
        HStack(spacing: MS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(available ? Color.accentColor : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MS.Font.caption).fontWeight(.semibold)
                    .foregroundStyle(available ? .primary : .secondary)
                Text(subtitle).font(MS.Font.micro).foregroundStyle(.secondary)
            }
            Spacer()
            if available {
                MSSecondaryButton("Export", icon: "square.and.arrow.up") {}
            } else {
                MSBadge(text: "Soon", color: .orange, size: .small)
            }
        }
        .padding(MS.Spacing.sm)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
    }
}
