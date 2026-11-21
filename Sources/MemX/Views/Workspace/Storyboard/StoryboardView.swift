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
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(workspaceVM.pipelineState.message)
                .font(MS.Font.body.weight(.medium))
                .foregroundStyle(MSColor.inkBright)
                .multilineTextAlignment(.center)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MSColor.surface2)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * workspaceVM.pipelineState.progress))
                }
            }
            .frame(width: 320, height: 6)
            .animation(.easeOut(duration: 0.25), value: workspaceVM.pipelineState.progress)
            Text("\(Int(workspaceVM.pipelineState.progress * 100))%")
                .font(MS.Font.mono)
                .foregroundStyle(MSColor.inkFaint)
            if workspaceVM.isCancellable {
                MSSecondaryButton("Cancel", icon: "xmark", isDestructive: true, size: .small) {
                    workspaceVM.cancelPipeline()
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MS.Spacing.xl)
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
                .background(MSColor.surface)

            MSVerticalDivider()
                .frame(maxHeight: .infinity)

            VStack(spacing: 0) {
                detailHeader
                if let item = selectedItem {
                    itemDetailPanel(item)
                } else {
                    overviewPanel
                }
            }
            .background(MSColor.canvas)
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
            MSPanelHeader(title: "Sequence", count: plan.sequence.count) {
                MSIconButton(icon: "arrow.clockwise", help: "Re-sequence") {
                    Task { await workspaceVM.buildSequence() }
                }
                .disabled(workspaceVM.isProcessing || workspaceVM.isRendering)
            }

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
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowSeparatorTint(MSColor.line)
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
            .scrollContentBackground(.hidden)
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

    private var detailHeader: some View {
        HStack(spacing: MS.Spacing.sm) {
            if let item = selectedItem {
                MSIconButton(icon: "chevron.left", help: "Back to overview") { selectedItemID = nil }
                let displayPosition = (plan.sequence.firstIndex(where: { $0.id == item.id }) ?? item.position) + 1
                Text("Clip \(displayPosition)")
                    .font(MS.Font.heading)
                    .foregroundStyle(MSColor.inkBright)
                if let sectionType = item.sectionType {
                    MSBadge(text: sectionType.rawValue, color: sectionType.displayColor, size: .small)
                }
            } else {
                Text("Overview")
                    .font(MS.Font.heading)
                    .foregroundStyle(MSColor.inkBright)
            }
            Spacer()
            MSSecondaryButton("Export Plan", icon: "square.and.arrow.up", size: .small) {
                showExportSheet = true
            }
        }
        .padding(.horizontal, MS.Spacing.md)
        .frame(height: MS.Height.bar)
        .background(MSColor.surface)
        .overlay(alignment: .bottom) { MSDivider() }
        .sheet(isPresented: $showExportSheet) {
            ExportPlanSheet(plan: plan)
        }
    }

    // MARK: - Item Detail Panel

    @ViewBuilder
    private func itemDetailPanel(_ item: MontageSequenceItem) -> some View {
        let itemAsset = assetsByID[item.assetID]
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.md) {
                if let asset = itemAsset {
                    AssetThumbnailView(asset: asset, size: 280, cornerRadius: MS.Radius.lg, isSelected: false, showOverlay: true)
                        .id(asset.id)
                        .frame(maxWidth: .infinity)
                        .padding(MS.Spacing.md)
                        .msCard(padding: 0)
                }

                VStack(alignment: .leading, spacing: 9) {
                    MSStatRow(label: "Start", value: formatTimestamp(item.startTime))
                    MSStatRow(label: "End", value: formatTimestamp(item.endTime))
                    MSStatRow(label: "Duration", value: formatDuration(item.duration))
                    if item.speedFactor < 1 {
                        MSStatRow(label: "Speed", value: String(format: "%.2g×", item.speedFactor))
                    }
                    MSStatRow(label: "Song energy", value: "\(Int(item.motionIntensity * 100))%")
                    HStack {
                        Text("Confidence")
                            .font(MS.Font.caption)
                            .foregroundStyle(MSColor.inkMuted)
                        Spacer()
                        ConfidenceBadge(score: item.confidenceScore)
                    }
                }
                .msCard()

                // Scene card — only shown when analysis populated caption or
                // labels. Skipped entirely for assets that were never analyzed.
                if let asset = itemAsset,
                   (asset.sceneCaption?.isEmpty == false) || (asset.sceneLabels?.isEmpty == false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scene").msEyebrow()
                        if let caption = asset.sceneCaption, !caption.isEmpty {
                            Text(caption)
                                .font(MS.Font.body)
                                .foregroundStyle(MSColor.inkBright)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let summary = asset.semanticSummary, !summary.isEmpty {
                            Text(summary)
                                .font(MS.Font.caption)
                                .foregroundStyle(MSColor.inkMuted)
                        }
                        if let labels = asset.sceneLabels, !labels.isEmpty {
                            FlowRow(spacing: 5) {
                                ForEach(labels, id: \.self) { MSBadge(text: $0, size: .small) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .msCard()
                }

                if !item.selectionReason.isEmpty || item.gradingHint != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Why selected").msEyebrow()
                        if !item.selectionReason.isEmpty {
                            FlowRow(spacing: 5) {
                                ForEach(item.selectionReason.components(separatedBy: " · "), id: \.self) {
                                    MSBadge(text: $0, size: .small)
                                }
                            }
                        }
                        if let hint = item.gradingHint {
                            Text("Grading: \(hint.rawValue.capitalized)")
                                .font(MS.Font.caption)
                                .foregroundStyle(MSColor.inkFaint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .msCard()
                }

                DisclosureGroup(isExpanded: $transitionsExpanded) {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        HStack {
                            Text("In").font(MS.Font.micro).foregroundStyle(MSColor.inkFaint).frame(width: 24, alignment: .leading)
                            transitionScrollRow(current: item.transitionIn) { trans in
                                workspaceVM.updateTransition(for: item, transitionIn: trans)
                            }
                        }
                        HStack {
                            Text("Out").font(MS.Font.micro).foregroundStyle(MSColor.inkFaint).frame(width: 24, alignment: .leading)
                            transitionScrollRow(current: item.transitionOut) { trans in
                                workspaceVM.updateTransition(for: item, transitionOut: trans)
                            }
                        }
                    }
                    .padding(.top, MS.Spacing.sm)
                } label: {
                    HStack(spacing: 8) {
                        Text("Transitions")
                            .font(MS.Font.body.weight(.medium))
                            .foregroundStyle(MSColor.inkBright)
                        Text("\(item.transitionIn.rawValue) → \(item.transitionOut.rawValue)")
                            .font(MS.Font.caption)
                            .foregroundStyle(MSColor.inkMuted)
                            .lineLimit(1)
                    }
                }
                .msCard()
            }
            .frame(maxWidth: 640)
            .padding(MS.Spacing.lg)
            .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading, spacing: MS.Spacing.md) {
                MSStatStrip(stats: summaryStats)

                renderPipelineSection

                if !plan.moodArc.isEmpty {
                    MoodArcChart(points: plan.moodArc)
                        .msCard()
                }
            }
            .frame(maxWidth: 760)
            .padding(MS.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
    }

    private var summaryStats: [MSStat] {
        var stats = [
            MSStat(label: "Duration", value: formatDuration(plan.totalDuration)),
            MSStat(label: "Clips", value: "\(plan.sequence.count)",
                   sub: "\(Set(plan.sequence.map(\.assetID)).count) unique"),
            MSStat(label: "Vibe", value: plan.settings.vibe.rawValue, sub: plan.settings.aspectRatio.rawValue),
        ]
        if !plan.excludedAssetIDs.isEmpty {
            stats.append(MSStat(label: "Unused", value: "\(plan.excludedAssetIDs.count)", sub: "assets left out"))
        }
        return stats
    }

    @ViewBuilder
    private var renderPipelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSPanelHeader(title: "Render") {
                MSPrimaryButton(
                    workspaceVM.renderedVideoURL != nil ? "Re-render" : "Render Movie",
                    icon: "film",
                    isLoading: workspaceVM.isRendering,
                    size: .small
                ) {
                    if workspaceVM.renderedVideoURL != nil {
                        showReRenderConfirm = true
                    } else {
                        Task { await workspaceVM.renderVideo() }
                    }
                }
                .disabled(workspaceVM.isRendering || workspaceVM.isProcessing || workspaceVM.montagePlan == nil || workspaceVM.assets.isEmpty)
                .help("Export Video (⇧⌘E)")
            }

            VStack(alignment: .leading, spacing: MS.Spacing.md) {
                songVolumeControl

                if workspaceVM.isRendering {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        HStack {
                            Text(workspaceVM.renderProgressMessage)
                                .font(MS.Font.caption).foregroundStyle(MSColor.inkMuted)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(workspaceVM.renderProgress * 100))%")
                                .font(MS.Font.mono).foregroundStyle(MSColor.inkFaint)
                        }
                        ProgressView(value: workspaceVM.renderProgress)
                            .progressViewStyle(.linear)
                        renderLogView
                        if workspaceVM.isCancellable {
                            MSSecondaryButton("Cancel", icon: "xmark", isDestructive: true, size: .small) {
                                workspaceVM.cancelPipeline()
                            }
                        }
                    }
                } else if let videoURL = workspaceVM.renderedVideoURL {
                    VStack(alignment: .leading, spacing: MS.Spacing.sm) {
                        MSCallout(tone: .success, title: "Rendered", message: videoURL.lastPathComponent) {
                            HStack(spacing: 6) {
                                MSSecondaryButton("Open", icon: "play.fill", size: .small) {
                                    NSWorkspace.shared.open(videoURL)
                                }
                                MSSecondaryButton("Show in Finder", size: .small) {
                                    NSWorkspace.shared.selectFile(videoURL.path, inFileViewerRootedAtPath: "")
                                }
                                Menu {
                                    Button("Delete rendered file", role: .destructive) {
                                        showDeleteConfirm = true
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                        if !workspaceVM.renderLog.isEmpty {
                            renderLogView
                        }
                    }
                } else if let error = workspaceVM.renderError {
                    MSCallout(tone: .danger, title: "Render failed", message: error)
                } else {
                    Text("Renders on-device with beat-locked cuts, transitions, Ken Burns motion and the song mixed in.")
                        .font(MS.Font.caption)
                        .foregroundStyle(MSColor.inkMuted)
                }
            }
            .padding(MS.Spacing.md)
        }
        .msCard(padding: 0)
    }

    // MARK: - Song Volume Control

    @ViewBuilder
    private var songVolumeControl: some View {
        let volume = Binding<Double>(
            get: { workspaceVM.project.settings.songVolume },
            set: { workspaceVM.setSongVolume(($0 * 20).rounded() / 20) }
        )
        VStack(alignment: .leading, spacing: MS.Spacing.xs) {
            HStack(spacing: MS.Spacing.xs) {
                Image(systemName: volume.wrappedValue == 0 ? "speaker.slash.fill"
                                  : volume.wrappedValue < 0.4 ? "speaker.wave.1.fill"
                                  : volume.wrappedValue < 0.75 ? "speaker.wave.2.fill"
                                  : "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(MSColor.inkFaint)
                    .frame(width: 18)
                Text("Song volume")
                    .font(MS.Font.caption.weight(.medium))
                    .foregroundStyle(MSColor.inkBright)
                Spacer()
                Text("\(Int(volume.wrappedValue * 100))%")
                    .font(MS.Font.mono)
                    .foregroundStyle(MSColor.inkMuted)
            }
            Slider(value: volume, in: 0...1)
                .controlSize(.small)
                .disabled(workspaceVM.isRendering)
            Text("Defaults to 50% so voices from video clips can breathe.")
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkFaint)
        }
    }

    // MARK: - Render Log View

    @ViewBuilder
    private var renderLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Render log").msEyebrow()
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
                .background(MSColor.canvas, in: RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous)
                    .strokeBorder(MSColor.line, lineWidth: 1))
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

    // MARK: - Helpers

    private func transitionChip(_ trans: TransitionType, current: TransitionType, action: @escaping () -> Void) -> some View {
        let isSelected = trans == current
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: trans.icon).font(.system(size: 10.5))
                Text(trans.rawValue).font(MS.Font.caption.weight(isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? MSColor.inkBright : MSColor.inkMuted)
            .padding(.horizontal, 9)
            .frame(height: MS.Height.controlSmall)
            .background(
                isSelected ? MSColor.surface2 : MSColor.surface,
                in: RoundedRectangle(cornerRadius: MS.Radius.md - 1, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: MS.Radius.md - 1, style: .continuous)
                .strokeBorder(isSelected ? MSColor.lineStrong : MSColor.line, lineWidth: 1))
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
        HStack(spacing: 10) {
            Text("\(position)")
                .font(MS.Font.mono)
                .foregroundStyle(MSColor.inkFaint)
                .frame(width: 26, alignment: .trailing)

            ZStack(alignment: .bottomLeading) {
                if let asset {
                    AssetThumbnailView(
                        asset: asset,
                        size: 52,
                        cornerRadius: MS.Radius.sm,
                        isSelected: false,
                        showOverlay: false
                    )
                    .frame(width: 52, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                        .fill(MSColor.surface2)
                        .frame(width: 52, height: 36)
                        .overlay(
                            Image(systemName: item.sectionType?.icon ?? "photo")
                                .font(.system(size: 12))
                                .foregroundStyle(MSColor.inkFaint)
                        )
                }

                if asset?.isVideo == true {
                    Image(systemName: "video.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }
            }
            .frame(width: 52, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(item.sectionType?.displayColor ?? MSColor.inkFaint)
                        .frame(width: 3, height: 11)
                    Text(item.sectionType?.rawValue ?? "—")
                        .font(MS.Font.caption.weight(.semibold))
                        .foregroundStyle(MSColor.inkBright)
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
                        MSBadge(text: "Repeat", size: .small)
                    }
                }
                Text(secondaryRowText(for: asset))
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1fs", item.duration))
                    .font(MS.Font.mono)
                    .foregroundStyle(MSColor.ink)
                Image(systemName: item.transitionIn.icon)
                    .font(.system(size: 9.5))
                    .foregroundStyle(MSColor.inkFaint)
                    .help(item.transitionIn.rawValue)
            }
        }
        .padding(.vertical, 2)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                MSSectionHeader(title: "Energy", subtitle: "Song energy across the montage")
                Spacer()
            }

            if points.isEmpty {
                Text("No data").font(MS.Font.caption).foregroundStyle(MSColor.inkFaint)
            } else {
                GeometryReader { geo in
                    let line = Path { path in
                        for (i, pt) in points.enumerated() {
                            let p = CGPoint(x: pt.position * geo.size.width, y: (1 - pt.energy) * geo.size.height)
                            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }
                    ZStack {
                        ForEach(1..<4) { i in
                            Rectangle().fill(MSColor.line).frame(height: 1)
                                .position(x: geo.size.width / 2, y: geo.size.height * CGFloat(i) / 4)
                        }
                        Path { path in
                            path.addPath(line)
                            path.addLine(to: CGPoint(x: (points.last?.position ?? 1) * geo.size.width, y: geo.size.height))
                            path.addLine(to: CGPoint(x: (points.first?.position ?? 0) * geo.size.width, y: geo.size.height))
                            path.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        line.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 110)

                HStack {
                    Text("Start")
                    Spacer()
                    Text("End")
                }
                .font(MS.Font.mono)
                .foregroundStyle(MSColor.inkFaint)
            }
        }
    }
}

// MARK: - ExportPlanSheet

struct ExportPlanSheet: View {
    let plan: MontagePlan
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Plan")
                    .font(MS.Font.title)
                    .foregroundStyle(MSColor.inkBright)
                Text("To export the finished video, use Render on the storyboard.")
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkMuted)
            }

            VStack(alignment: .leading, spacing: 0) {
                exportOption(icon: "doc.badge.arrow.up", title: "JSON Storyboard", subtitle: "Machine-readable plan for custom pipelines", available: true, action: exportJSON)
                exportOption(icon: "doc.text", title: "Edit Decision List (.edl)", subtitle: "Import into Premiere, DaVinci, or Final Cut", available: false, action: nil)
                exportOption(icon: "doc.richtext", title: "PDF Shot List", subtitle: "Printable shot-by-shot breakdown", available: false, action: nil)
            }

            if let error = exportError {
                HStack(spacing: MS.Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(MS.Font.caption).foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                MSSecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(MS.Spacing.lg)
        .frame(width: 440)
        .background(MSColor.surface)
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
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(MSColor.inkMuted)
                .frame(width: 32, height: 32)
                .background(MSColor.surface2, in: RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MS.Font.body.weight(.medium))
                    .foregroundStyle(MSColor.inkBright)
                Text(subtitle).font(MS.Font.caption).foregroundStyle(MSColor.inkMuted)
            }
            Spacer()
            if available, let action {
                MSSecondaryButton("Export", size: .small, action: action)
            } else {
                MSBadge(text: "Soon", size: .small)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { MSDivider() }
        .opacity(available ? 1.0 : 0.55)
        .disabled(!available)
        .help(available ? "" : "Coming soon")
    }
}
