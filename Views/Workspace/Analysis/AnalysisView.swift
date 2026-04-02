import SwiftUI

struct AnalysisView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        HStack(spacing: 0) {
            // Left: Pipeline progress
            pipelinePanel
                .frame(width: 300)

            MSDivider()
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // Right: Details
            ScrollView {
                LazyVStack(spacing: MS.Spacing.md) {
                    if workspaceVM.hasAnalysisResult {
                        eventClusters
                        candidateScores
                    } else if !workspaceVM.isAnalyzing {
                        AnalysisPromptCard(
                            assetCount: workspaceVM.totalAssetCount,
                            canAnalyze: workspaceVM.canAnalyze
                        )
                    }
                }
                .padding(MS.Spacing.lg)
            }
        }
    }

    // MARK: - Pipeline Panel

    private var pipelinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Pipeline")
                    .font(MS.Font.heading)
                Text("On-device analysis stages")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(MS.Spacing.md)

            MSDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AnalysisPhase.allCases.dropFirst(), id: \.self) { phase in
                        pipelineRow(phase: phase)
                        if phase != .complete {
                            Rectangle()
                                .fill(.separator)
                                .frame(width: 1, height: 16)
                                .padding(.leading, 29)
                        }
                    }
                }
                .padding(MS.Spacing.md)
            }

            // Progress bar
            MSDivider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(workspaceVM.analysisStatus.message)
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Text("\(Int(workspaceVM.analysisStatus.progress * 100))%")
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 5)
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: geo.size.width * workspaceVM.analysisStatus.progress, height: 5)
                            .animation(.spring(), value: workspaceVM.analysisStatus.progress)
                    }
                }
                .frame(height: 5)
            }
            .padding(MS.Spacing.md)
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func pipelineRow(phase: AnalysisPhase) -> some View {
        let currentIdx = workspaceVM.analysisStatus.phase.index
        let phaseIdx = phase.index
        let isActive = phaseIdx == currentIdx && workspaceVM.isAnalyzing
        let isComplete = phaseIdx < currentIdx || workspaceVM.analysisStatus.isComplete

        PhaseProgressBadge(phase: phase, isActive: isActive, isComplete: isComplete)
            .padding(.vertical, MS.Spacing.sm)
    }

    // MARK: - Event Clusters

    private var eventClusters: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(
                title: "Event Clusters",
                subtitle: "Moments automatically grouped by visual & temporal similarity"
            )

            let events = workspaceVM.analysisResult?.events ?? MockDataProvider.mockEvents()
            ForEach(events) { event in
                EventClusterCard(event: event)
            }
        }
    }

    // MARK: - Candidate Scores

    private var candidateScores: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            MSSectionHeader(
                title: "Clip Candidates",
                subtitle: "Ranked by quality · emotion · novelty"
            )

            let candidates = (workspaceVM.analysisResult?.candidates ?? [])
                .sorted { $0.overallScore > $1.overallScore }
                .prefix(12)

            ForEach(Array(candidates)) { candidate in
                CandidateScoreRow(candidate: candidate)
            }
        }
    }
}

// MARK: - AnalysisPromptCard

struct AnalysisPromptCard: View {
    let assetCount: Int
    let canAnalyze: Bool
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        VStack(spacing: MS.Spacing.lg) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "cpu.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Ready to Analyze")
                    .font(MS.Font.title)
                Text(canAnalyze
                    ? "Start the AI pipeline to analyze \(assetCount) assets, cluster events, score moments, and build a storyboard."
                    : "Import some media first to run analysis.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: MS.Spacing.md) {
                ForEach(pipelineSteps, id: \.0) { step in
                    VStack(spacing: 4) {
                        Image(systemName: step.1)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                        Text(step.0)
                            .font(MS.Font.micro)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(MS.Spacing.sm)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
                }
            }

            MSPrimaryButton(
                workspaceVM.isAnalyzing ? "Analyzing..." : "Start Analysis",
                icon: workspaceVM.isAnalyzing ? nil : "sparkles",
                isLoading: workspaceVM.isAnalyzing
            ) {
                Task { await workspaceVM.runAnalysis() }
            }
            .disabled(!canAnalyze || workspaceVM.isAnalyzing)
        }
        .frame(maxWidth: .infinity)
        .msCard(padding: MS.Spacing.xl)
    }

    private var pipelineSteps: [(String, String)] {[
        ("Scene Detection", "eye.fill"),
        ("Embeddings", "waveform.path.ecg"),
        ("Event Clustering", "circle.hexagongrid.fill"),
        ("Moment Scoring", "star.fill"),
        ("Soundtrack", "music.note"),
    ]}
}

// MARK: - EventClusterCard

struct EventClusterCard: View {
    let event: MemoryEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            HStack {
                EmotionBadge(emotion: event.dominantEmotion)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.label)
                        .font(MS.Font.heading)
                    Text("\(event.assetIDs.count) assets")
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ScoreRing(score: event.importanceScore, size: 36)

                Button {
                    withAnimation(.spring()) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: MS.Spacing.xs) {
                    Text(event.description)
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)

                    MSScoreBar(label: "Importance", value: event.importanceScore, color: .accentColor)

                    // Asset ID chips (would show thumbnails in full implementation)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(event.assetIDs.prefix(8), id: \.self) { id in
                                Text(String(id.suffix(6)))
                                    .font(MS.Font.micro)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            if event.assetIDs.count > 8 {
                                Text("+\(event.assetIDs.count - 8) more")
                                    .font(MS.Font.micro)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .msCard()
    }
}

// MARK: - CandidateScoreRow

struct CandidateScoreRow: View {
    let candidate: ClipCandidate

    var body: some View {
        HStack(spacing: MS.Spacing.md) {
            // Score ring
            ScoreRing(score: candidate.overallScore, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: MS.Spacing.xs) {
                    Text(String(candidate.assetID.suffix(8)))
                        .font(MS.Font.mono)
                        .foregroundStyle(.primary)

                    if candidate.faces > 0 {
                        MSBadge(text: "\(candidate.faces) face\(candidate.faces > 1 ? "s" : "")", size: .small)
                    }
                    if !candidate.isIncluded {
                        MSBadge(text: "Excluded", color: .red, size: .small)
                    }
                }

                HStack(spacing: MS.Spacing.sm) {
                    miniBar(label: "Q", value: candidate.qualityScore, color: .blue)
                    miniBar(label: "E", value: candidate.emotionScore, color: .pink)
                    miniBar(label: "N", value: candidate.noveltyScore, color: .purple)
                    if candidate.motionScore > 0 {
                        miniBar(label: "M", value: candidate.motionScore, color: .orange)
                    }
                }
            }

            Spacer()

            ConfidenceBadge(score: candidate.overallScore)
        }
        .padding(MS.Spacing.sm)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
    }

    private func miniBar(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(MS.Font.micro)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(color.opacity(0.3))
                .frame(width: 40, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: 40 * CGFloat(value), height: 4)
                }
        }
    }
}
