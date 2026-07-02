import SwiftUI

// MARK: - PipelineRunView
//
// Full-screen "Run Pipeline" stage. Takes over the workspace detail area
// when the user kicks off the full pipeline. Shows phase rail on the left,
// live progress + activity log on the right.

struct PipelineRunView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        HStack(spacing: 0) {
            phaseRail
                .frame(width: 280)
                .background(.regularMaterial)

            MSVerticalDivider()
                .frame(maxHeight: .infinity)

            activityPane
        }
    }

    // MARK: - Phase Rail

    private var phaseRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pipeline")
                    .font(MS.Font.heading)
                Text("Processing stages")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(MS.Spacing.md)

            MSDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let phases: [ProcessingPhase] = [.analyzingAudio, .scoringPhotos, .sequencing, .complete]
                    ForEach(Array(phases.enumerated()), id: \.element) { idx, phase in
                        ProcessingPhaseRow(
                            phase: phase,
                            isActive: workspaceVM.processingStatus.phase == phase && workspaceVM.isProcessing,
                            isComplete: phaseIsComplete(phase)
                        )
                        if idx < phases.count - 1 {
                            Rectangle()
                                .fill(.separator)
                                .frame(width: 1, height: 14)
                                .padding(.leading, 27)
                        }
                    }
                }
                .padding(MS.Spacing.md)
            }

            MSDivider()

            stats
                .padding(MS.Spacing.md)

            Spacer(minLength: 0)
        }
    }

    private var stats: some View {
        let s = workspaceVM.openRouterStats
        let apiValue: String = {
            if !workspaceVM.openRouterAvailable { return "Missing key" }
            if s.success + s.failure == 0 { return "Connected" }
            return "\(s.success) ok · \(s.failure) failed"
        }()
        let apiIcon: String = {
            if !workspaceVM.openRouterAvailable { return "exclamationmark.triangle.fill" }
            if s.failure > 0 && s.success == 0 { return "xmark.octagon.fill" }
            if s.failure > 0 { return "exclamationmark.triangle.fill" }
            return "checkmark.circle.fill"
        }()
        return VStack(alignment: .leading, spacing: MS.Spacing.xs) {
            Text("Run Stats")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
            MSStatRow(label: "OpenRouter", value: apiValue, icon: apiIcon)
            if let song = workspaceVM.songTrack {
                MSStatRow(label: "Song", value: song.displayTitle, icon: "music.note")
            }
            if let bm = workspaceVM.beatmap {
                MSStatRow(label: "BPM", value: "\(Int(bm.bpm))", icon: "metronome")
                MSStatRow(label: "Beats", value: "\(bm.beats.count)", icon: "waveform.path.ecg")
                if !bm.hooks.isEmpty {
                    MSStatRow(label: "Hooks", value: "\(bm.hooks.count)", icon: "arrow.triangle.2.circlepath")
                }
            }
            MSStatRow(label: "Photos", value: "\(workspaceVM.photoCount)", icon: "photo")
            MSStatRow(label: "Videos", value: "\(workspaceVM.videoCount)", icon: "video")
            if workspaceVM.hasScoredAssets {
                MSStatRow(label: "Scored", value: "\(scoredAssetCount)/\(workspaceVM.totalAssetCount)", icon: "star.fill")
            }
            if let plan = workspaceVM.montagePlan {
                MSStatRow(label: "Clips", value: "\(plan.sequence.count)", icon: "film.stack")
            }
        }
    }

    private var scoredAssetCount: Int {
        workspaceVM.assets.filter { $0.analysisScore != nil }.count
    }

    // MARK: - Activity Pane

    private var activityPane: some View {
        VStack(spacing: 0) {
            header
            MSDivider()
            ScrollView {
                VStack(spacing: MS.Spacing.lg) {
                    heroProgress
                    if let err = workspaceVM.processingStatus.error {
                        errorBanner(err)
                    } else if !workspaceVM.isProcessing && workspaceVM.processingStatus.isComplete {
                        successBanner
                    } else if !workspaceVM.isProcessing && workspaceVM.montagePlan == nil {
                        idleNotice
                    }
                    openRouterFailureBanner
                    activityLog
                    actionRow
                }
                .padding(MS.Spacing.lg)
            }
        }
    }

    private var header: some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
            Text("Running Pipeline")
                .font(MS.Font.heading)
            Spacer()
            phaseBadge
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, MS.Spacing.sm)
        .background(.bar)
    }

    private var phaseBadge: some View {
        let phase = workspaceVM.processingStatus.phase
        let label: String = {
            if workspaceVM.processingStatus.error != nil { return "Error" }
            if workspaceVM.processingStatus.isComplete { return "Complete" }
            return phase.rawValue
        }()
        let color: Color = {
            if workspaceVM.processingStatus.error != nil { return .red }
            if workspaceVM.processingStatus.isComplete { return .green }
            if workspaceVM.isProcessing { return .orange }
            return .secondary
        }()
        return MSBadge(text: label, color: color, size: .small)
    }

    private var heroProgress: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(workspaceVM.processingStatus.message.isEmpty
                     ? workspaceVM.processingStatus.phase.description
                     : workspaceVM.processingStatus.message)
                    .font(MS.Font.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                Text("\(Int(workspaceVM.processingStatus.progress * 100))%")
                    .font(MS.Font.heading)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .frame(width: max(0, geo.size.width * workspaceVM.processingStatus.progress), height: 8)
                        .shadow(color: Color.accentColor.opacity(workspaceVM.isProcessing ? 0.35 : 0), radius: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: workspaceVM.processingStatus.progress)
                }
            }
            .frame(height: 8)

            HStack(spacing: 4) {
                phaseSegment(phase: .analyzingAudio)
                phaseSegment(phase: .scoringPhotos)
                phaseSegment(phase: .sequencing)
            }
            .frame(height: 4)
        }
        .padding(MS.Spacing.md)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous))
    }

    private func phaseSegment(phase: ProcessingPhase) -> some View {
        let isActive = workspaceVM.processingStatus.phase == phase && workspaceVM.isProcessing
        let isComplete = phaseIsComplete(phase)
        let color: Color = isComplete ? .green : (isActive ? .orange : Color.secondary.opacity(0.25))
        return Capsule().fill(color)
    }

    private var idleNotice: some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
            Text(workspaceVM.cancelledNotice ?? "Pipeline stopped before completion. Press Run Pipeline to retry.")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(MS.Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
    }

    private var successBanner: some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Storyboard ready — \(workspaceVM.montagePlan?.sequence.count ?? 0) clips assembled.")
                .font(MS.Font.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(MS.Spacing.sm)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
    }

    @ViewBuilder
    private var openRouterFailureBanner: some View {
        let s = workspaceVM.openRouterStats
        if s.failure > 0 {
            VStack(alignment: .leading, spacing: MS.Spacing.xs) {
                HStack(spacing: MS.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("OpenRouter rejected \(s.failure) request\(s.failure == 1 ? "" : "s") — falling back to basic metadata for those assets.")
                        .font(MS.Font.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                if let last = s.lastFailure {
                    Text(last)
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text("Tip: set OPENROUTER_VISION_MODEL in .env to a model your account can call (e.g. google/gemini-flash-1.5, openai/gpt-4o-mini).")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
            }
            .padding(MS.Spacing.sm)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: MS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(MS.Font.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(MS.Spacing.sm)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
    }

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            HStack {
                Text("Activity")
                    .font(MS.Font.heading)
                Spacer()
                Text("\(workspaceVM.pipelineLog.count) entries")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
            }
            if workspaceVM.pipelineLog.isEmpty {
                HStack {
                    Text("No activity yet.")
                        .font(MS.Font.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(MS.Spacing.md)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(workspaceVM.pipelineLog) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(MS.Spacing.sm)
                    }
                    .frame(maxHeight: 280)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
                    .onChange(of: workspaceVM.pipelineLog.count) { _, _ in
                        if let last = workspaceVM.pipelineLog.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ entry: PipelineLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MS.Spacing.sm) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(MS.Font.micro)
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text("\(Int(entry.progress * 100))%")
                .font(MS.Font.micro)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
            Image(systemName: entry.phase.icon)
                .font(.system(size: 9))
                .foregroundStyle(phaseColor(entry.phase))
                .frame(width: 12)
            Text(entry.message)
                .font(MS.Font.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func phaseColor(_ phase: ProcessingPhase) -> Color {
        switch phase {
        case .analyzingAudio:    return .blue
        case .scoringPhotos:     return .orange
        case .sequencing:        return .purple
        case .complete:          return .green
        case .idle:              return .secondary
        }
    }

    // MARK: - Action Row

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: MS.Spacing.sm) {
            if workspaceVM.isCancellable {
                MSSecondaryButton("Cancel Pipeline", icon: "xmark", isDestructive: true) {
                    workspaceVM.cancelPipeline()
                }
            } else if workspaceVM.montagePlan != nil {
                MSPrimaryButton("View Storyboard", icon: "film.stack.fill") {
                    workspaceVM.goToStage(.storyboard)
                }
                MSSecondaryButton("Re-run", icon: "arrow.clockwise") {
                    Task { await workspaceVM.runPipeline() }
                }
            } else {
                MSPrimaryButton("Run Pipeline", icon: "sparkles") {
                    Task { await workspaceVM.runPipeline() }
                }
                .disabled(!workspaceVM.canRunPipeline)
            }
            Spacer()
        }
    }

    // MARK: - Phase completion logic

    private func phaseIsComplete(_ phase: ProcessingPhase) -> Bool {
        if workspaceVM.processingStatus.isComplete { return true }
        let currentIndex = workspaceVM.processingStatus.phase.index
        if phase.index < currentIndex { return true }
        switch phase {
        case .analyzingAudio:  return workspaceVM.hasBeatmap
        case .scoringPhotos:   return workspaceVM.allAssetsScored
        case .sequencing:      return workspaceVM.hasPlan
        case .complete:        return workspaceVM.hasPlan
        case .idle:            return false
        }
    }
}

// MARK: - ProcessingPhaseRow

struct ProcessingPhaseRow: View {
    let phase: ProcessingPhase
    let isActive: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: MS.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 26, height: 26)
                if isActive {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: isComplete ? "checkmark" : phase.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isComplete || isActive ? .white : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(phase.rawValue)
                    .font(MS.Font.caption)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .primary : (isComplete ? .secondary : .tertiary))
                if isActive {
                    Text(phase.description)
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MS.Spacing.sm)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    private var circleColor: Color {
        if isActive   { return .accentColor }
        if isComplete { return .green }
        return Color.secondary.opacity(0.2)
    }
}
