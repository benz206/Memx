import SwiftUI

struct WorkspaceView: View {
    let project: Project
    @Environment(AppViewModel.self) private var appVM
    @State private var workspaceVM: WorkspaceViewModel

    init(project: Project) {
        self.project = project
        _workspaceVM = State(initialValue: WorkspaceViewModel(
            project: project,
            appVM: AppViewModel()
        ))
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            detailContent
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appVM.showProjects()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Projects")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ToolbarItem(placement: .principal) {
                titleField
            }

            ToolbarItem(placement: .primaryAction) {
                toolbarActions
            }
        }
        .environment(workspaceVM)
        .onAppear {
            workspaceVM = WorkspaceViewModel(project: project, appVM: appVM)
            if workspaceVM.assets.isEmpty && !project.assetIDs.isEmpty {
                let allMock = MockDataProvider.mockAssets()
                let mapped = project.assetIDs.compactMap { id in allMock.first { $0.id == id } }
                workspaceVM.addAssets(mapped.isEmpty ? allMock : mapped)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(WorkspaceTab.allCases, id: \.self, selection: $workspaceVM.selectedTab) { tab in
            HStack(spacing: MS.Spacing.sm) {
                Text("\(tab.stepNumber)")
                    .font(MS.Font.micro)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Label(tab.rawValue, systemImage: tab.icon)
                    .font(MS.Font.body)
            }
            .tag(tab)
        }
        .listStyle(.sidebar)
        .navigationTitle(workspaceVM.project.title)
        .safeAreaInset(edge: .bottom) {
            sidebarStats
        }
    }

    private var sidebarStats: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.xs) {
            MSDivider()
            VStack(alignment: .leading, spacing: 6) {
                if let song = workspaceVM.songTrack {
                    MSStatRow(label: "Song", value: song.displayTitle, icon: "music.note")
                    if let bpm = song.bpm {
                        MSStatRow(label: "BPM", value: "\(Int(bpm))", icon: "waveform")
                    }
                } else {
                    MSStatRow(label: "Song", value: "None", icon: "music.note")
                }
                MSStatRow(label: "Photos", value: "\(workspaceVM.photoCount)", icon: "photo")
                MSStatRow(label: "Videos", value: "\(workspaceVM.videoCount)", icon: "video")
                MSStatRow(label: "Status", value: workspaceVM.project.status.rawValue, icon: "info.circle")
            }
            .padding(MS.Spacing.sm)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        Group {
            switch workspaceVM.selectedTab {
            case .song:
                SongImportView()
            case .photos:
                ImportView()
            case .motionPrompts:
                MotionPromptsView()
            case .storyboard:
                StoryboardView()
            }
        }
        .environment(workspaceVM)
    }

    // MARK: - Title Field

    private var titleField: some View {
        Group {
            if workspaceVM.isEditingTitle {
                TextField("Project Title", text: $workspaceVM.project.title)
                    .textFieldStyle(.plain)
                    .font(MS.Font.heading)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 200)
                    .onSubmit {
                        workspaceVM.updateTitle(workspaceVM.project.title)
                        workspaceVM.isEditingTitle = false
                    }
                    .onExitCommand { workspaceVM.isEditingTitle = false }
            } else {
                Button {
                    workspaceVM.isEditingTitle = true
                } label: {
                    Text(workspaceVM.project.title)
                        .font(MS.Font.heading)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Toolbar Actions

    private var toolbarActions: some View {
        HStack(spacing: MS.Spacing.sm) {
            MSBadge(
                text: workspaceVM.project.status.rawValue,
                color: statusColor(workspaceVM.project.status),
                size: .small
            )

            // Run pipeline shortcut from storyboard/motion tabs
            if workspaceVM.selectedTab == .motionPrompts || workspaceVM.selectedTab == .storyboard {
                if workspaceVM.hasPlan {
                    MSSecondaryButton("Re-run", icon: "arrow.clockwise") {
                        Task { await workspaceVM.runPipeline() }
                    }
                    .disabled(workspaceVM.isProcessing)
                } else if !workspaceVM.assets.isEmpty && workspaceVM.hasBeatmap {
                    MSPrimaryButton(
                        workspaceVM.isProcessing ? "Processing..." : "Run Pipeline",
                        icon: workspaceVM.isProcessing ? nil : "sparkles",
                        isLoading: workspaceVM.isProcessing
                    ) {
                        Task { await workspaceVM.runPipeline() }
                    }
                    .disabled(!workspaceVM.canRunPipeline)
                }
            }
        }
    }

    private func statusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .draft:     return .secondary
        case .importing: return .blue
        case .analyzing: return .orange
        case .ready:     return .green
        case .exported:  return .purple
        }
    }
}
