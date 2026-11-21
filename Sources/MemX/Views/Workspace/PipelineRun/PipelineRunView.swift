import SwiftUI

// MARK: - PipelineRunView

struct PipelineRunView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MS.Spacing.lg) {
                MSPageHeader(
                    title: "Analysis",
                    subtitle: "Beat detection, on-device photo understanding, and sequencing."
                ) {
                    actionRow
                }

                MSStatStrip(stats: stats)

                progressPanel

                if let err = workspaceVM.pipelineState.errorMessage {
                    MSCallout(tone: .danger, title: "Pipeline failed", message: err)
                } else if case .completed = workspaceVM.pipelineState {
                    MSCallout(tone: .success, title: "Storyboard ready",
                              message: "\(workspaceVM.montagePlan?.sequence.count ?? 0) clips assembled and cut to the beat.")
                } else if !workspaceVM.isProcessing && workspaceVM.montagePlan == nil {
                    MSCallout(message: workspaceVM.pipelineState == .idle
                              ? "Pipeline stopped before completion. Press Run Pipeline to retry."
                              : workspaceVM.pipelineState.message)
                }

                activityLog
            }
            .msPage(maxWidth: 880)
        }
    }

    private var stats: [MSStat] {
        var result = [MSStat]()
        if let bm = workspaceVM.beatmap {
            result.append(MSStat(label: "Tempo", value: "\(Int(bm.bpm.rounded()))", sub: "BPM"))
            result.append(MSStat(label: "Beats", value: "\(bm.beats.count)",
                                 sub: bm.hooks.isEmpty ? "no hooks" : "\(bm.hooks.count) hooks"))
        } else {
            result.append(MSStat(label: "Tempo", value: "—", sub: "not analyzed"))
        }
        result.append(MSStat(label: "Analyzed", value: "\(scoredAssetCount)/\(workspaceVM.totalAssetCount)",
                             sub: "\(workspaceVM.photoCount) photos · \(workspaceVM.videoCount) videos"))
        result.append(MSStat(label: "Clips", value: workspaceVM.montagePlan.map { "\($0.sequence.count)" } ?? "—",
                             sub: workspaceVM.montagePlan == nil ? "not built" : "in storyboard"))
        return result
    }

    private var scoredAssetCount: Int {
        workspaceVM.assets.filter { $0.analysisScore != nil }.count
    }

    // MARK: - Progress

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                let phases: [ProcessingPhase] = [.analyzingAudio, .scoringPhotos, .sequencing]
                ForEach(Array(phases.enumerated()), id: \.element) { idx, phase in
                    if idx > 0 { MSVerticalDivider() }
                    ProcessingPhaseRow(
                        phase: phase,
                        isActive: workspaceVM.pipelineState.phase == phase && workspaceVM.isProcessing,
                        isComplete: phaseIsComplete(phase)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MS.Spacing.md)
                    .padding(.vertical, 12)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            MSDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(workspaceVM.pipelineState.message.isEmpty
                         ? workspaceVM.pipelineState.phase.description
                         : workspaceVM.pipelineState.message)
                        .font(MS.Font.body.weight(.medium))
                        .foregroundStyle(MSColor.inkBright)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(workspaceVM.pipelineState.progress * 100))%")
                        .font(MS.Font.mono)
                        .foregroundStyle(MSColor.inkMuted)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MSColor.surface2)
                        Capsule()
                            .fill(workspaceVM.pipelineState.errorMessage != nil ? MSColor.danger : Color.accentColor)
                            .frame(width: max(0, geo.size.width * workspaceVM.pipelineState.progress))
                    }
                }
                .frame(height: 6)
                .animation(.easeOut(duration: 0.25), value: workspaceVM.pipelineState.progress)
            }
            .padding(MS.Spacing.md)
        }
        .msCard(padding: 0)
    }

    // MARK: - Activity

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSPanelHeader(title: "Activity", count: workspaceVM.pipelineLog.count)

            if workspaceVM.pipelineLog.isEmpty {
                Text("No activity yet.")
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(workspaceVM.pipelineLog) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 300)
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
        .msCard(padding: 0)
    }

    private func logRow(_ entry: PipelineLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(MSColor.inkFaint)
            Text("\(Int(entry.progress * 100))%")
                .foregroundStyle(MSColor.inkFaint)
                .frame(width: 34, alignment: .trailing)
            Circle()
                .fill(phaseColor(entry.phase))
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(entry.message)
                .foregroundStyle(MSColor.ink)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(MS.Font.mono)
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, 3)
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
        case .complete:          return MSColor.success
        case .idle:              return MSColor.inkFaint
        }
    }

    // MARK: - Action Row

    @ViewBuilder
    private var actionRow: some View {
        if workspaceVM.isCancellable {
            MSSecondaryButton("Cancel", icon: "xmark", isDestructive: true) {
                workspaceVM.cancelPipeline()
            }
            .help("Stop (⌘.)")
        } else if workspaceVM.montagePlan != nil {
            MSSecondaryButton("Re-run", icon: "arrow.clockwise") {
                Task { await workspaceVM.runPipeline() }
            }
            .disabled(workspaceVM.isRendering)
            .help("Run Pipeline (⌘R)")
            MSPrimaryButton("View Storyboard", icon: "arrow.right") {
                workspaceVM.goToStage(.storyboard)
            }
            .help("Storyboard (⌘4)")
        } else {
            MSPrimaryButton("Run Pipeline", icon: "sparkles") {
                Task { await workspaceVM.runPipeline() }
            }
            .disabled(!workspaceVM.canRunPipeline)
            .help("Run Pipeline (⌘R)")
        }
    }

    // MARK: - Phase completion logic

    private func phaseIsComplete(_ phase: ProcessingPhase) -> Bool {
        if workspaceVM.pipelineState.phase == .complete { return true }
        let currentIndex = workspaceVM.pipelineState.phase.index
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
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 22, height: 22)
                if isActive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isComplete ? "checkmark" : phase.icon)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isComplete ? MSColor.success : MSColor.inkFaint)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(phase.rawValue)
                    .font(MS.Font.caption.weight(.medium))
                    .foregroundStyle(isActive || isComplete ? MSColor.inkBright : MSColor.inkMuted)
                Text(isActive ? "Running" : (isComplete ? "Done" : "Waiting"))
                    .font(MS.Font.micro.weight(.regular))
                    .foregroundStyle(isActive ? Color.accentColor : MSColor.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    private var circleColor: Color {
        if isActive   { return Color.accentColor.opacity(0.14) }
        if isComplete { return MSColor.success.opacity(0.14) }
        return MSColor.surface2
    }
}
