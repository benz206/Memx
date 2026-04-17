import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StoryboardView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        Group {
            if let plan = workspaceVM.montagePlan {
                StoryboardContentView(plan: plan)
            } else if workspaceVM.isGeneratingPlan || workspaceVM.isProcessing {
                generatingView
            } else {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No Storyboard Yet",
                    subtitle: workspaceVM.hasSong && !workspaceVM.assets.isEmpty
                        ? "Generate motion prompts first, then build the sequence."
                        : "Import a song and photos to get started.",
                    action: workspaceVM.hasSong && !workspaceVM.assets.isEmpty
                        ? ("Go to Motion", { workspaceVM.selectedTab = .motionPrompts })
                        : nil
                )
            }
        }
    }

    private var generatingView: some View {
        VStack(spacing: MS.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
            Text(workspaceVM.processingStatus.message)
                .font(MS.Font.heading)
                .foregroundStyle(.secondary)
            Text("\(Int(workspaceVM.processingStatus.progress * 100))%")
                .font(MS.Font.caption)
                .foregroundStyle(.tertiary)
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
            sequenceList
                .frame(minWidth: 320, maxWidth: 380)

            MSDivider().frame(width: 1).frame(maxHeight: .infinity)

            VStack(spacing: 0) {
                planSummaryHeader
                MSDivider()
                if let item = selectedItem {
                    itemDetailPanel(item)
                } else {
                    overviewPanel
                }
            }
        }
    }

    // MARK: - Sequence List

    private var sequenceList: some View {
        VStack(spacing: 0) {
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
                    Task { await workspaceVM.buildSequence() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Re-sequence")
                .disabled(workspaceVM.isProcessing || workspaceVM.isGeneratingPlan)
            }
            .padding(MS.Spacing.md)

            MSDivider()

            List(selection: $selectedItem) {
                ForEach(plan.sequence) { item in
                    StoryboardSequenceRow(item: item, position: item.position + 1, isSelected: selectedItem?.id == item.id)
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
                summaryItem(icon: "aspectratio", label: "Ratio", value: plan.settings.aspectRatio.rawValue)
                if !plan.excludedAssetIDs.isEmpty {
                    summaryItem(icon: "photo.badge.minus", label: "Excluded", value: "\(plan.excludedAssetIDs.count)")
                }
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
                HStack {
                    Text("Clip \(item.position + 1)")
                        .font(MS.Font.title)
                    if let sectionType = item.sectionType {
                        MSBadge(text: sectionType.rawValue, size: .small)
                    }
                    Spacer()
                    ConfidenceBadge(score: item.confidenceScore)
                }

                if let asset = workspaceVM.assets.first(where: { $0.id == item.assetID }) {
                    AssetThumbnailView(asset: asset, size: 200, cornerRadius: MS.Radius.md, isSelected: false, showOverlay: true)
                        .frame(maxWidth: .infinity)
                }

                // Timing
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Timing")
                    MSStatRow(label: "Start", value: formatTimestamp(item.startTime), icon: "play.fill")
                    MSStatRow(label: "End", value: formatTimestamp(item.endTime), icon: "stop.fill")
                    MSStatRow(label: "Duration", value: formatDuration(item.duration), icon: "timer")
                    if item.beatAligned {
                        HStack(spacing: 4) {
                            BeatAlignedBadge()
                            Spacer()
                        }
                    }
                }
                .msCard()

                // Motion Prompt
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Motion Direction")
                    if item.motionPrompt.isEmpty {
                        Text("No motion prompt generated yet.")
                            .font(MS.Font.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(item.motionPrompt)
                            .font(MS.Font.body)
                            .foregroundStyle(.secondary)
                    }
                    MSStatRow(label: "Intensity", value: "\(Int(item.motionIntensity * 100))%", icon: "bolt")
                }
                .msCard()

                // Transitions
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Transitions")
                    HStack {
                        Text("In").font(MS.Font.micro).foregroundStyle(.tertiary).frame(width: 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MS.Spacing.xs) {
                                ForEach(TransitionType.allCases, id: \.self) { trans in
                                    transitionChip(trans, current: item.transitionIn) {
                                        workspaceVM.updateTransition(for: item, transitionIn: trans)
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Text("Out").font(MS.Font.micro).foregroundStyle(.tertiary).frame(width: 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MS.Spacing.xs) {
                                ForEach(TransitionType.allCases, id: \.self) { trans in
                                    transitionChip(trans, current: item.transitionOut) {
                                        workspaceVM.updateTransition(for: item, transitionOut: trans)
                                    }
                                }
                            }
                        }
                    }
                }
                .msCard()

                // Selection reason
                if !item.selectionReason.isEmpty {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        MSSectionHeader(title: "Why Selected")
                        Text(item.selectionReason)
                            .font(MS.Font.body)
                            .foregroundStyle(.secondary)
                    }
                    .msCard()
                }
            }
            .padding(MS.Spacing.md)
        }
    }

    // MARK: - Overview Panel

    private var overviewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.lg) {
                // Song card
                if let song = workspaceVM.songTrack {
                    selectedSongCard(song)
                }

                // Energy arc
                if !plan.moodArc.isEmpty {
                    MoodArcChart(points: plan.moodArc)
                        .frame(height: 160)
                        .msCard()
                }

                // Render pipeline
                renderPipelineSection
            }
            .padding(MS.Spacing.md)
        }
    }

    private func selectedSongCard(_ song: SongTrack) -> some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(title: "Selected Song")
            HStack(spacing: MS.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.3), .purple.opacity(0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: song.fileFormatIcon)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.displayTitle)
                        .font(MS.Font.caption).fontWeight(.semibold)
                    Text(song.displayArtist)
                        .font(MS.Font.micro).foregroundStyle(.secondary)
                }
                Spacer()
                if let bpm = song.bpm {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(bpm)) BPM")
                            .font(MS.Font.micro).foregroundStyle(.secondary)
                        Text(song.durationString)
                            .font(MS.Font.micro).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .msCard()
    }

    @ViewBuilder
    private var renderPipelineSection: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(title: "Render Pipeline", subtitle: "AVFoundation composition + audio mix")

            if workspaceVM.isRendering {
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    ProgressView(value: workspaceVM.renderProgress)
                        .tint(.accentColor)
                    HStack {
                        Text(workspaceVM.renderProgressMessage)
                            .font(MS.Font.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(workspaceVM.renderProgress * 100))%")
                            .font(MS.Font.micro).foregroundStyle(.tertiary)
                    }
                }
            } else if let videoURL = workspaceVM.renderedVideoURL {
                HStack(spacing: MS.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Render complete").font(MS.Font.caption).fontWeight(.semibold)
                        Text(videoURL.lastPathComponent).font(MS.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    MSSecondaryButton("Show in Finder", icon: "folder") {
                        NSWorkspace.shared.selectFile(videoURL.path, inFileViewerRootedAtPath: "")
                    }
                }
                .padding(MS.Spacing.sm)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
            } else if let error = workspaceVM.renderError {
                HStack(spacing: MS.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(MS.Font.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(MS.Spacing.sm)
                .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
            } else {
                VStack(spacing: MS.Spacing.xs) {
                    ForEach(renderSteps, id: \.0) { step in
                        HStack(spacing: MS.Spacing.sm) {
                            Image(systemName: step.1).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.0).font(MS.Font.caption).foregroundStyle(.secondary)
                                Text(step.2).font(MS.Font.micro).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            MSPrimaryButton(
                workspaceVM.renderedVideoURL != nil ? "Re-render" : "Render Video",
                icon: "film.fill",
                isLoading: workspaceVM.isRendering
            ) {
                Task { await workspaceVM.renderVideo() }
            }
            .disabled(workspaceVM.isRendering || workspaceVM.montagePlan == nil || workspaceVM.assets.isEmpty)
        }
        .msCard()
    }

    private var renderSteps: [(String, String, String)] {[
        ("2.5D Parallax / Motion Generation", "square.stack.3d.up", "MiDaS depth → animated camera layers per photo"),
        ("AVComposition Assembly", "film.fill", "Stitch clips using AVMutableComposition"),
        ("Audio Mix", "waveform", "Align song via AVAudioMix, snapped to beatmap"),
        ("Transition Rendering", "sparkles", "Core Image filters for crossfades, flash whites, dissolves"),
        ("Export Session", "arrow.down.circle", "AVAssetExportSession → H.264 / HEVC"),
    ]}

    // MARK: - Helpers

    private func summaryItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(MS.Font.caption).fontWeight(.medium)
            Text(label).font(MS.Font.micro).foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }

    private func transitionChip(_ trans: TransitionType, current: TransitionType, action: @escaping () -> Void) -> some View {
        let isSelected = trans == current
        return Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: trans.icon).font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(trans.rawValue).font(.system(size: 8))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
            .padding(5)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
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
            Text("\(position)")
                .font(MS.Font.mono)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                .fill(sectionColor(item.sectionType).opacity(0.15))
                .frame(width: 52, height: 36)
                .overlay(
                    Image(systemName: item.sectionType?.icon ?? "photo.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(sectionColor(item.sectionType).opacity(0.7))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.sectionType?.rawValue ?? "—")
                        .font(MS.Font.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if item.beatAligned { BeatAlignedBadge() }
                }
                HStack(spacing: MS.Spacing.xs) {
                    Text(String(format: "%.1fs", item.duration))
                        .font(MS.Font.micro).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    HStack(spacing: 2) {
                        Image(systemName: item.transitionIn.icon).font(.system(size: 9))
                        Text(item.transitionIn.rawValue).font(MS.Font.micro)
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()
            ConfidenceBadge(score: item.confidenceScore, style: .icon)
        }
        .contentShape(Rectangle())
    }

    private func sectionColor(_ type: SectionType?) -> Color {
        switch type {
        case .intro, .outro:  return .gray
        case .verse:          return .blue
        case .preChorus:      return .teal
        case .chorus:         return .indigo
        case .buildup:        return .orange
        case .drop:           return .red
        case .bridge:         return .purple
        case .breakdown:      return .mint
        case .none:           return .secondary
        }
    }
}

// MARK: - MoodArcChart

struct MoodArcChart: View {
    let points: [MoodPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(title: "Energy Arc", subtitle: "Energy and valence through the song")

            if points.isEmpty {
                Text("No data").font(MS.Font.caption).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    ZStack {
                        // Energy (orange)
                        Path { path in
                            for (i, pt) in points.enumerated() {
                                let x = pt.position * geo.size.width
                                let y = (1 - pt.energy) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else       { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        // Valence (blue)
                        Path { path in
                            for (i, pt) in points.enumerated() {
                                let x = pt.position * geo.size.width
                                let y = (1 - pt.valence) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else       { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        // Dots at vocal peaks
                        ForEach(points.prefix(8), id: \.position) { pt in
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 4, height: 4)
                                .position(x: pt.position * geo.size.width, y: (1 - pt.valence) * geo.size.height)
                        }
                    }
                }
                .frame(height: 80)

                HStack(spacing: MS.Spacing.lg) {
                    legendItem(color: .accentColor, label: "Valence")
                    legendItem(color: .orange, label: "Energy")
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

// MARK: - ExportPlanSheet

struct ExportPlanSheet: View {
    let plan: MontagePlan
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String? = nil

    var body: some View {
        VStack(spacing: MS.Spacing.lg) {
            Text("Export Montage Plan")
                .font(MS.Font.title)

            VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                exportOption(icon: "doc.text", title: "Edit Decision List (.edl)", subtitle: "Import into Premiere, DaVinci, or Final Cut", available: false, action: nil)
                exportOption(icon: "doc.badge.arrow.up", title: "JSON Storyboard", subtitle: "Machine-readable plan for custom pipelines", available: true, action: exportJSON)
                exportOption(icon: "doc.richtext", title: "PDF Shot List", subtitle: "Printable shot-by-shot breakdown", available: false, action: nil)
                exportOption(icon: "film.fill", title: "Rendered Video (AVFoundation)", subtitle: "On-device render pipeline — coming soon", available: false, action: nil)
            }

            if let error = exportError {
                HStack(spacing: MS.Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(MS.Font.caption).foregroundStyle(.red)
                }
            }

            MSSecondaryButton("Close") { dismiss() }
        }
        .padding(MS.Spacing.xl)
        .frame(width: 420)
    }

    private func exportJSON() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan) else {
            exportError = "Failed to encode storyboard."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "\(plan.title.isEmpty ? "storyboard" : plan.title).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { self.exportError = error.localizedDescription }
            }
        }
    }

    private func exportOption(icon: String, title: String, subtitle: String, available: Bool, action: (() -> Void)?) -> some View {
        HStack(spacing: MS.Spacing.md) {
            Image(systemName: icon).font(.system(size: 20))
                .foregroundStyle(available ? Color.accentColor : Color.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MS.Font.caption).fontWeight(.semibold)
                    .foregroundStyle(available ? .primary : .secondary)
                Text(subtitle).font(MS.Font.micro).foregroundStyle(.secondary)
            }
            Spacer()
            if available, let action {
                MSSecondaryButton("Export", icon: "square.and.arrow.up", action: action)
            } else {
                MSBadge(text: "Soon", color: .orange, size: .small)
            }
        }
        .padding(MS.Spacing.sm)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
    }
}
