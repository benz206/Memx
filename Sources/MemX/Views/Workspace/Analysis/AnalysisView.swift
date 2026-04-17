import SwiftUI

// MARK: - MotionPromptsView
// Step 3: Review and edit the AI-generated motion directions for each photo.

struct MotionPromptsView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM

    var body: some View {
        HStack(spacing: 0) {
            // Left: pipeline status panel
            pipelinePanel
                .frame(width: 280)

            MSDivider()
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // Right: prompt grid
            VStack(spacing: 0) {
                promptToolbar
                MSDivider()
                promptContent
            }
        }
    }

    // MARK: - Pipeline Panel

    private var pipelinePanel: some View {
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
                    ForEach(ProcessingPhase.allCases.dropFirst(), id: \.self) { phase in
                        ProcessingPhaseRow(phase: phase,
                                          isActive: workspaceVM.processingStatus.phase == phase && workspaceVM.isProcessing,
                                          isComplete: phase.index < workspaceVM.processingStatus.phase.index || workspaceVM.processingStatus.isComplete)
                        if phase != .complete {
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

            // Progress bar
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(workspaceVM.processingStatus.message)
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Text("\(Int(workspaceVM.processingStatus.progress * 100))%")
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 5)
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: geo.size.width * workspaceVM.processingStatus.progress, height: 5)
                            .animation(.spring(), value: workspaceVM.processingStatus.progress)
                    }
                }
                .frame(height: 5)
            }
            .padding(MS.Spacing.md)

            // Generate all button
            MSPrimaryButton(
                workspaceVM.isProcessing ? "Generating..." : "Generate All Prompts",
                icon: workspaceVM.isProcessing ? nil : "sparkles",
                isLoading: workspaceVM.isProcessing
            ) {
                Task { await workspaceVM.generateAllMotionPrompts() }
            }
            .disabled(workspaceVM.assets.isEmpty || workspaceVM.isProcessing)
            .padding(MS.Spacing.md)
        }
        .background(.regularMaterial)
    }

    // MARK: - Toolbar

    private var promptToolbar: some View {
        HStack(spacing: MS.Spacing.sm) {
            Text("\(workspaceVM.assets.count) photos")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)

            Divider().frame(height: 18)

            let readyCount = workspaceVM.readyPromptCount
            MSBadge(
                text: "\(readyCount) / \(workspaceVM.assets.count) ready",
                color: readyCount == workspaceVM.assets.count ? .green : .orange,
                size: .small
            )

            Spacer()

            if workspaceVM.hasMotionPrompts {
                MSPrimaryButton("Build Storyboard", icon: "film.stack.fill") {
                    Task { await workspaceVM.buildSequence() }
                }
                .disabled(workspaceVM.isProcessing || workspaceVM.isGeneratingPlan)
            }
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, MS.Spacing.sm)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var promptContent: some View {
        if workspaceVM.assets.isEmpty {
            EmptyStateView(
                icon: "photo.stack",
                title: "No Photos Yet",
                subtitle: "Add photos in the Photos tab first.",
                action: ("Go to Photos", { workspaceVM.selectedTab = .photos })
            )
        } else if workspaceVM.motionPrompts.isEmpty && !workspaceVM.isProcessing {
            generatePromptCTA
        } else {
            promptGrid
        }
    }

    private var generatePromptCTA: some View {
        VStack(spacing: MS.Spacing.lg) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "sparkles")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Generate Motion Prompts")
                    .font(MS.Font.title)
                Text("Each photo gets a cinematographer's direction — a short note on how it should breathe and move to the music.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            MSPrimaryButton("Generate All Prompts", icon: "sparkles") {
                Task { await workspaceVM.generateAllMotionPrompts() }
            }
            .disabled(workspaceVM.isProcessing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MS.Spacing.xl)
    }

    private var promptGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: MS.Spacing.md)],
                spacing: MS.Spacing.md
            ) {
                ForEach(workspaceVM.assets) { asset in
                    MotionPromptCard(
                        asset: asset,
                        prompt: workspaceVM.motionPrompts.first { $0.assetID == asset.id }
                    )
                }
            }
            .padding(MS.Spacing.md)
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
                    .foregroundStyle(isActive ? .primary : isComplete ? .secondary : .tertiary)
                if isActive {
                    Text(phase.description)
                        .font(MS.Font.micro)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
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

// MARK: - MotionPromptCard

struct MotionPromptCard: View {
    let asset: MediaAsset
    let prompt: MotionPrompt?
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            // Thumbnail
            AssetThumbnailView(asset: asset, size: 180, cornerRadius: MS.Radius.sm, isSelected: false, showOverlay: false)
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipped()

            // Status + intensity
            HStack(spacing: MS.Spacing.xs) {
                if let p = prompt {
                    statusBadge(p.status)
                    Spacer()
                    intensityBar(p.motionIntensity)
                } else {
                    MSBadge(text: "Pending", size: .small)
                    Spacer()
                }
            }

            // Prompt text
            if isEditing {
                VStack(spacing: MS.Spacing.xs) {
                    TextEditor(text: $editText)
                        .font(MS.Font.caption)
                        .frame(minHeight: 60, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous))

                    HStack(spacing: MS.Spacing.sm) {
                        Button("Cancel") {
                            isEditing = false
                        }
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)

                        Spacer()

                        MSSecondaryButton("Save") {
                            if let p = prompt {
                                workspaceVM.setMotionPromptEdited(id: p.id, text: editText)
                            }
                            isEditing = false
                        }
                    }
                }
            } else {
                Text(prompt?.prompt.isEmpty == false ? prompt!.prompt : "Tap Edit to write a motion direction...")
                    .font(MS.Font.caption)
                    .foregroundStyle(prompt?.prompt.isEmpty == false ? .primary : .tertiary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Edit") {
                    editText = prompt?.prompt ?? ""
                    isEditing = true
                }
                .font(MS.Font.micro)
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }
        }
        .msCard()
    }

    private func statusBadge(_ status: MotionPromptStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon).font(.system(size: 9))
            Text(status.rawValue).font(MS.Font.micro)
        }
        .foregroundStyle(statusColor(status))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor(status).opacity(0.1), in: Capsule())
    }

    private func statusColor(_ status: MotionPromptStatus) -> Color {
        switch status {
        case .pending:    return .secondary
        case .generating: return .orange
        case .ready:      return .green
        case .edited:     return .blue
        }
    }

    private func intensityBar(_ intensity: Float) -> some View {
        HStack(spacing: 3) {
            Text("Motion")
                .font(MS.Font.micro)
                .foregroundStyle(.tertiary)
            Capsule()
                .fill(.quaternary)
                .frame(width: 40, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 40 * CGFloat(intensity), height: 3)
                }
        }
    }
}
