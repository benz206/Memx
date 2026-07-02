import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StoryboardView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        VStack(spacing: 0) {
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
                            ? "Build the sequence from the prepared media, or run the full pipeline."
                            : "Import a song and photos to get started.",
                        action: workspaceVM.hasSong && !workspaceVM.assets.isEmpty
                            ? ("Build Storyboard", { Task { await workspaceVM.buildSequence() } })
                            : nil
                    )
                }
            }
        }
    }

    private var generatingView: some View {
        VStack(spacing: MS.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text(workspaceVM.processingStatus.message)
                .font(MS.Font.heading)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Progress bar — mirrors the pipeline panel style.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Text("\(Int(workspaceVM.processingStatus.progress * 100))%")
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: workspaceVM.processingStatus.progress)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.25), value: workspaceVM.processingStatus.progress)

                // Two tiny segmented sub-bars — visual scoring / sequence.
                HStack(spacing: 4) {
                    phaseSegment(phase: .scoringPhotos)
                    phaseSegment(phase: .sequencing)
                }
                .frame(height: 3)
            }
            .frame(maxWidth: 360)

            if workspaceVM.isCancellable {
                MSSecondaryButton("Cancel", icon: "xmark", isDestructive: true) {
                    workspaceVM.cancelPipeline()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MS.Spacing.xl)
    }

    private func phaseSegment(phase: ProcessingPhase) -> some View {
        let isActive = workspaceVM.processingStatus.phase == phase && workspaceVM.isProcessing
        let isComplete: Bool = {
            if workspaceVM.processingStatus.isComplete { return true }
            return phase.index < workspaceVM.processingStatus.phase.index
        }()
        let color: Color = isComplete ? .green : (isActive ? .orange : Color.secondary.opacity(0.25))
        return Capsule()
            .fill(color)
            .frame(height: 3)
    }
}

// MARK: - StoryboardContentView

struct StoryboardContentView: View {
    let plan: MontagePlan
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @State private var selectedItemID: UUID? = nil
    @State private var showExportSheet = false
    @State private var showDeleteConfirm = false
    @State private var showReRenderConfirm = false
    @State private var transitionsExpanded = false

    private var selectedItem: MontageSequenceItem? {
        guard let id = selectedItemID else { return nil }
        return plan.sequence.first(where: { $0.id == id })
    }

    /// Asset IDs that appear in more than one sequence item.
    private var repeatedAssetIDs: Set<String> {
        var counts = [String: Int]()
        for item in plan.sequence { counts[item.assetID, default: 0] += 1 }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private var assetsByID: [String: MediaAsset] {
        Dictionary(workspaceVM.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        HStack(spacing: 0) {
            sequenceList
                .frame(minWidth: 320, maxWidth: 380)

            MSVerticalDivider()
                .frame(maxHeight: .infinity)

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
        .confirmationDialog("Delete rendered file?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { workspaceVM.deleteExport() }
        }
        .confirmationDialog(
            "Replace existing render? This will overwrite the current file.",
            isPresented: $showReRenderConfirm
        ) {
            Button("Replace", role: .destructive) {
                Task { await workspaceVM.renderVideo() }
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

            List(selection: $selectedItemID) {
                let repeated = repeatedAssetIDs
                let assetMap = assetsByID
                ForEach(Array(plan.sequence.enumerated()), id: \.element.id) { idx, item in
                    StoryboardSequenceRow(
                        item: item,
                        position: idx + 1,
                        asset: assetMap[item.assetID],
                        isSelected: selectedItemID == item.id,
                        isRepeatedClip: repeated.contains(item.assetID)
                    )
                        .tag(item.id)
                        .onTapGesture { selectedItemID = item.id }
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                workspaceVM.removeSequenceItem(item)
                                if selectedItemID == item.id { selectedItemID = nil }
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
            .onDeleteCommand {
                guard let id = selectedItemID,
                      let item = plan.sequence.first(where: { $0.id == id }) else { return }
                workspaceVM.removeSequenceItem(item)
                selectedItemID = nil
            }
            .onChange(of: plan.sequence) { _, newSequence in
                if let id = selectedItemID, !newSequence.contains(where: { $0.id == id }) {
                    selectedItemID = nil
                }
            }
            .onChange(of: workspaceVM.isGeneratingPlan) { _, gen in
                if gen { selectedItemID = nil }
            }
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
                MSSecondaryButton("Export Plan (JSON)", icon: "square.and.arrow.up") {
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
        let displayPosition = (plan.sequence.firstIndex(where: { $0.id == item.id }) ?? item.position) + 1
        let itemAsset = assetsByID[item.assetID]
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.md) {
                HStack {
                    Text("Clip \(displayPosition)")
                        .font(MS.Font.title)
                    if let sectionType = item.sectionType {
                        MSBadge(text: sectionType.rawValue, size: .small)
                    }
                    Spacer()
                    ConfidenceBadge(score: item.confidenceScore)
                }

                if let asset = itemAsset {
                    AssetThumbnailView(asset: asset, size: 200, cornerRadius: MS.Radius.md, isSelected: false, showOverlay: true)
                        .id(asset.id)
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    MSSectionHeader(title: "Timing")
                    MSStatRow(label: "Start", value: formatTimestamp(item.startTime), icon: "play.fill")
                    MSStatRow(label: "End", value: formatTimestamp(item.endTime), icon: "stop.fill")
                    MSStatRow(label: "Duration", value: formatDuration(item.duration), icon: "timer")
                }
                .msCard()

                // Scene card — only shown when analysis populated caption or
                // labels. Skipped entirely for assets that were never analyzed.
                if let asset = itemAsset,
                   (asset.sceneCaption?.isEmpty == false) || (asset.sceneLabels?.isEmpty == false) {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        MSSectionHeader(title: "Scene")
                        if let caption = asset.sceneCaption, !caption.isEmpty {
                            Text(caption).font(MS.Font.body).foregroundStyle(.primary)
                        } else if let labels = asset.sceneLabels, !labels.isEmpty {
                            Text(labels.joined(separator: " · "))
                                .font(MS.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let caption = asset.sceneCaption, !caption.isEmpty,
                           let labels = asset.sceneLabels, !labels.isEmpty {
                            Text(labels.joined(separator: " · "))
                                .font(MS.Font.micro)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .msCard()
                }

                if let asset = itemAsset,
                   let summary = asset.semanticSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        MSSectionHeader(title: "Embedding Read")
                        Text(summary)
                            .font(MS.Font.body)
                            .foregroundStyle(.secondary)
                        if let dimensions = asset.semanticEmbedding?.count {
                            MSStatRow(label: "Vector", value: "\(dimensions) dimensions", icon: "point.3.connected.trianglepath.dotted")
                        }
                        MSStatRow(label: "Song Energy", value: "\(Int(item.motionIntensity * 100))%", icon: "bolt")
                    }
                    .msCard()
                }

                if !item.selectionReason.isEmpty || item.gradingHint != nil {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        MSSectionHeader(title: "Why Selected")
                        if !item.selectionReason.isEmpty {
                            Text(item.selectionReason)
                                .font(MS.Font.body)
                                .foregroundStyle(.secondary)
                        }
                        if let hint = item.gradingHint {
                            Text("Grading: \(hint.rawValue.capitalized)")
                                .font(MS.Font.micro)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .msCard()
                }

                DisclosureGroup(isExpanded: $transitionsExpanded) {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        HStack {
                            Text("In").font(MS.Font.micro).foregroundStyle(.tertiary).frame(width: 20)
                            transitionScrollRow(current: item.transitionIn) { trans in
                                workspaceVM.updateTransition(for: item, transitionIn: trans)
                            }
                        }
                        HStack {
                            Text("Out").font(MS.Font.micro).foregroundStyle(.tertiary).frame(width: 20)
                            transitionScrollRow(current: item.transitionOut) { trans in
                                workspaceVM.updateTransition(for: item, transitionOut: trans)
                            }
                        }
                    }
                    .padding(.top, MS.Spacing.xs)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.transitionIn.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Transitions")
                            .font(MS.Font.caption)
                            .foregroundStyle(.secondary)
                        Text("\(item.transitionIn.rawValue) → \(item.transitionOut.rawValue)")
                            .font(MS.Font.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .msCard()
            }
            .padding(MS.Spacing.md)
        }
    }

    private func transitionScrollRow(current: TransitionType, onSelect: @escaping (TransitionType) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MS.Spacing.xs) {
                ForEach(TransitionType.allCases, id: \.self) { trans in
                    transitionChip(trans, current: current) { onSelect(trans) }
                }
            }
            .padding(.horizontal, 16)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    // MARK: - Overview Panel

    private var overviewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.lg) {
                if let song = workspaceVM.songTrack {
                    selectedSongCard(song)
                }

                if !plan.moodArc.isEmpty {
                    MoodArcChart(points: plan.moodArc)
                        .frame(height: 160)
                        .msCard()
                }

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
                        .fill(Color.accentColor.opacity(0.12))
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

            songVolumeControl

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
                    renderLogView
                    if workspaceVM.isCancellable {
                        MSSecondaryButton("Cancel", icon: "xmark", isDestructive: true) {
                            workspaceVM.cancelPipeline()
                        }
                    }
                }
            } else if let videoURL = workspaceVM.renderedVideoURL {
                VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                    HStack(spacing: MS.Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rendered").font(MS.Font.caption).fontWeight(.semibold)
                            Text(videoURL.lastPathComponent).font(MS.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button("Delete rendered file", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: MS.Spacing.sm) {
                        MSSecondaryButton("Open", icon: "play.circle") {
                            NSWorkspace.shared.open(videoURL)
                        }
                        MSSecondaryButton("Show in Finder", icon: "folder") {
                            NSWorkspace.shared.selectFile(videoURL.path, inFileViewerRootedAtPath: "")
                        }
                        Spacer()
                    }
                    if !workspaceVM.renderLog.isEmpty {
                        renderLogView
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
                    ForEach(renderSteps, id: \.title) { step in
                        HStack(spacing: MS.Spacing.sm) {
                            Image(systemName: step.implemented ? step.icon : "lock.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(step.title)
                                        .font(MS.Font.caption)
                                        .foregroundStyle(.secondary)
                                    if !step.implemented {
                                        Text("Coming soon")
                                            .font(MS.Font.micro)
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.quaternary.opacity(0.5), in: Capsule())
                                    }
                                }
                                Text(step.subtitle)
                                    .font(MS.Font.micro)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .opacity(step.implemented ? 1.0 : 0.5)
                    }
                }
            }

            MSPrimaryButton(
                workspaceVM.renderedVideoURL != nil ? "Re-render" : "Render Movie",
                icon: "film.fill",
                isLoading: workspaceVM.isRendering
            ) {
                if workspaceVM.renderedVideoURL != nil {
                    showReRenderConfirm = true
                } else {
                    Task { await workspaceVM.renderVideo() }
                }
            }
            .disabled(workspaceVM.isRendering || workspaceVM.montagePlan == nil || workspaceVM.assets.isEmpty)
            .help("Export Video (⇧⌘E)")
        }
        .msCard()
    }

    // MARK: - Song Volume Control

    @ViewBuilder
    private var songVolumeControl: some View {
        let volume = Binding<Double>(
            get: { workspaceVM.project.settings.songVolume },
            set: { workspaceVM.setSongVolume($0) }
        )
        VStack(alignment: .leading, spacing: MS.Spacing.xs) {
            HStack(spacing: MS.Spacing.xs) {
                Image(systemName: volume.wrappedValue == 0 ? "speaker.slash.fill"
                                  : volume.wrappedValue < 0.4 ? "speaker.wave.1.fill"
                                  : volume.wrappedValue < 0.75 ? "speaker.wave.2.fill"
                                  : "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Song Volume")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(volume.wrappedValue * 100))%")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Slider(value: volume, in: 0...1, step: 0.05)
                .disabled(workspaceVM.isRendering)
            Text("Defaults to 50% so voices from video clips can breathe.")
                .font(MS.Font.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, MS.Spacing.xs)
    }

    // MARK: - Render Log View

    @ViewBuilder
    private var renderLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("Pipeline log")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(workspaceVM.renderLog) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(formatLogTime(entry.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 60, alignment: .leading)
                                Text("\(Int(entry.progress * 100))%")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(MS.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous))
                .onChange(of: workspaceVM.renderLog.count) { _, _ in
                    if let lastID = workspaceVM.renderLog.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func formatLogTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private struct RenderStep {
        let title: String
        let icon: String
        let subtitle: String
        let implemented: Bool
    }

    private var renderSteps: [RenderStep] {[
        RenderStep(title: "Stitch clips (AVMutableComposition)", icon: "film.fill", subtitle: "Assemble clips into a composition", implemented: true),
        RenderStep(title: "Attach audio track", icon: "waveform", subtitle: "Align song via AVAudioMix, snapped to beatmap", implemented: true),
        RenderStep(title: "Export (AVAssetExportSession)", icon: "arrow.down.circle", subtitle: "H.264 / HEVC output file", implemented: true),
        RenderStep(title: "2.5D Parallax / Motion Generation", icon: "square.stack.3d.up", subtitle: "MiDaS depth → animated camera layers", implemented: false),
        RenderStep(title: "Transition Rendering", icon: "sparkles", subtitle: "Core Image filters for crossfades, flash whites", implemented: false),
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
                Text(trans.rawValue).font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
            .padding(6)
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
        if t < 10 { return String(format: "%.1fs", t) }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        String(format: "%.2fs", t)
    }

    private func embeddingRead(for asset: MediaAsset) -> String {
        if let summary = asset.semanticSummary, !summary.isEmpty { return summary }
        if let caption = asset.sceneCaption, !caption.isEmpty { return caption }
        if let labels = asset.sceneLabels, !labels.isEmpty { return labels.joined(separator: " · ") }
        return "No semantic read available yet."
    }
}

// MARK: - StoryboardSequenceRow

struct StoryboardSequenceRow: View {
    let item: MontageSequenceItem
    let position: Int
    let asset: MediaAsset?
    let isSelected: Bool
    var isRepeatedClip: Bool = false

    var body: some View {
        HStack(spacing: MS.Spacing.sm) {
            Text("\(position)")
                .font(MS.Font.mono)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            ZStack(alignment: .topTrailing) {
                if let asset {
                    AssetThumbnailView(
                        asset: asset,
                        size: 52,
                        cornerRadius: MS.Radius.xs,
                        isSelected: false,
                        showOverlay: false
                    )
                    .frame(width: 52, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                        .fill((item.sectionType?.displayColor ?? .secondary).opacity(0.15))
                        .frame(width: 52, height: 36)
                        .overlay(
                            Image(systemName: item.sectionType?.icon ?? "photo.fill")
                                .font(.system(size: 13))
                                .foregroundStyle((item.sectionType?.displayColor ?? .secondary).opacity(0.7))
                        )
                }

                if asset?.isVideo == true {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(2)
                }
            }
            .frame(width: 52, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
                    .stroke((item.sectionType?.displayColor ?? .secondary).opacity(0.45), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.sectionType?.rawValue ?? "—")
                        .font(MS.Font.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if item.isHookMoment {
                        let label: String = {
                            if let r = item.hookRepeatIndex, r > 0 { return "Hook ×\(r + 1)" }
                            return "Hook"
                        }()
                        MSBadge(text: label, color: .indigo, size: .small)
                    }
                    if item.isAnticipationHold {
                        MSBadge(text: "Hold", color: .purple, size: .small)
                    }
                    if isRepeatedClip {
                        MSBadge(text: "⟲ Repeat", color: .orange, size: .small)
                    }
                }
                Text(secondaryRowText(for: asset))
                    .font(MS.Font.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: MS.Spacing.xs) {
                    Text(String(format: "%.1fs", item.duration))
                        .font(MS.Font.micro).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Image(systemName: item.transitionIn.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(item.transitionIn.rawValue)
                }
            }

            Spacer()
            ConfidenceBadge(score: item.confidenceScore, style: .icon)
        }
        .contentShape(Rectangle())
    }

    /// Distinct one-liner per asset. Prefers analysis captions, falls back
    /// to facts derived from the asset itself so the storyboard doesn't
    /// show the same string on every row when analysis is unavailable.
    private func secondaryRowText(for asset: MediaAsset?) -> String {
        if let summary = asset?.semanticSummary, !summary.isEmpty { return summary }
        if let caption = asset?.sceneCaption, !caption.isEmpty { return caption }
        if let labels = asset?.sceneLabels, !labels.isEmpty {
            return labels.prefix(3).joined(separator: " · ")
        }
        return Self.basicAssetFact(for: asset)
    }

    private static let factDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static func basicAssetFact(for asset: MediaAsset?) -> String {
        guard let asset else { return "Memory clip" }
        var parts: [String] = []
        parts.append(asset.isVideo ? "Video" : (asset.aspectRatio < 0.85 ? "Photo · portrait" : (asset.aspectRatio > 1.4 ? "Photo · wide" : "Photo")))
        if asset.isVideo, asset.duration > 0 {
            parts.append(String(format: "%.1fs", asset.duration))
        }
        if let date = asset.creationDate {
            parts.append(factDateFormatter.string(from: date))
        }
        if asset.isFavorite { parts.append("favorite") }
        return parts.joined(separator: " · ")
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
                        Path { path in
                            for (i, pt) in points.enumerated() {
                                let x = pt.position * geo.size.width
                                let y = (1 - pt.energy) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else       { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        Path { path in
                            for (i, pt) in points.enumerated() {
                                let x = pt.position * geo.size.width
                                let y = (1 - pt.valence) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else       { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        ForEach(points.prefix(20), id: \.position) { pt in
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 4, height: 4)
                                .position(x: pt.position * geo.size.width, y: (1 - pt.valence) * geo.size.height)
                        }
                    }
                }
                .frame(height: 80)

                HStack(spacing: MS.Spacing.lg) {
                    legendItem(color: .accentColor, label: "Valence (dots = highest-valence peaks)")
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
        .opacity(available ? 1.0 : 0.45)
        .disabled(!available)
        .help(available ? "" : "Coming soon")
    }
}
