import SwiftUI
import Photos

struct WorkspaceView: View {
    let project: Project
    @Environment(AppViewModel.self) private var appVM
    @State private var workspaceVM: WorkspaceViewModel
    @State private var showMissingAssetsBanner = false
    @State private var showLeaveConfirm = false
    @State private var isTitleHovered = false

    init(project: Project, appVM: AppViewModel) {
        self.project = project
        _workspaceVM = State(initialValue: WorkspaceViewModel(project: project, appVM: appVM))
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
                    if workspaceVM.isProcessing || workspaceVM.isRendering {
                        showLeaveConfirm = true
                    } else {
                        appVM.showProjects()
                    }
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
        .confirmationDialog(
            "Leave project? Current pipeline will be cancelled.",
            isPresented: $showLeaveConfirm
        ) {
            Button("Leave", role: .destructive) {
                workspaceVM.cancelPipeline()
                appVM.showProjects()
            }
            Button("Stay", role: .cancel) {}
        }
        .environment(workspaceVM)
        .onAppear {
            Task { await workspaceVM.restoreAssets() }
        }
        .onChange(of: workspaceVM.isRestoringAssets) { _, isRestoring in
            if !isRestoring {
                showMissingAssetsBanner = !workspaceVM.assetsFullyRestored
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(WorkspaceTab.allCases, id: \.self, selection: $workspaceVM.selectedTab) { tab in
            HStack(spacing: MS.Spacing.sm) {
                stepIcon(for: tab)
                    .frame(width: 16)
                Label(tab.rawValue, systemImage: tab.icon)
                    .font(MS.Font.body)
            }
            .tag(tab)
        }
        .listStyle(.sidebar)
        .navigationTitle(workspaceVM.project.title)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private func stepIcon(for tab: WorkspaceTab) -> some View {
        if isTabComplete(tab) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        } else if isTabActive(tab) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func isTabComplete(_ tab: WorkspaceTab) -> Bool {
        switch tab {
        case .song:          return workspaceVM.hasSong
        case .photos:        return !workspaceVM.assets.isEmpty
        case .motionPrompts: return workspaceVM.hasMotionPrompts
        case .storyboard:    return workspaceVM.montagePlan != nil
        }
    }

    private func isTabActive(_ tab: WorkspaceTab) -> Bool {
        switch tab {
        case .song:          return true
        case .photos:        return workspaceVM.hasSong
        case .motionPrompts: return !workspaceVM.assets.isEmpty
        case .storyboard:    return workspaceVM.hasMotionPrompts || workspaceVM.hasPlan
        }
    }

    private var sidebarFooter: some View {
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
                MSStatRow(label: "Status", value: statusDisplayName(workspaceVM.project.status), icon: "info.circle")

                if workspaceVM.hasSong && !workspaceVM.assets.isEmpty {
                    MSDivider()
                    if workspaceVM.hasPlan {
                        MSSecondaryButton("Re-run Pipeline", icon: "arrow.clockwise") {
                            Task { await workspaceVM.runPipeline() }
                        }
                        .disabled(workspaceVM.isProcessing)
                    } else {
                        MSPrimaryButton(
                            workspaceVM.isProcessing ? "Processing..." : "Run Pipeline",
                            icon: workspaceVM.isProcessing ? nil : "sparkles",
                            isLoading: workspaceVM.isProcessing
                        ) {
                            Task { await workspaceVM.runPipeline() }
                        }
                        .disabled(!workspaceVM.canRunPipeline)
                    }

                    if workspaceVM.isCancellable {
                        MSSecondaryButton("Cancel", icon: "xmark", isDestructive: true) {
                            workspaceVM.cancelPipeline()
                        }
                    }
                }
            }
            .padding(MS.Spacing.sm)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .restricted {
                photosAccessBanner
            }

            if workspaceVM.isRestoringAssets {
                HStack(spacing: MS.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading media…")
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, MS.Spacing.md)
                .padding(.vertical, MS.Spacing.sm)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) { MSDivider() }
            }

            if showMissingAssetsBanner {
                missingAssetsBanner
            }

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
        }
        .environment(workspaceVM)
    }

    private var photosAccessBanner: some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Photos access is denied. Grant access to load your library.")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
            .font(MS.Font.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, MS.Spacing.sm)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { MSDivider() }
    }

    private var missingAssetsBanner: some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: "photo.badge.exclamationmark.fill").foregroundStyle(.orange)
            Text("Some assets from this project are no longer available. Add media to continue.")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Pick Media") {
                workspaceVM.selectedTab = .photos
                showMissingAssetsBanner = false
            }
            .font(MS.Font.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Button {
                showMissingAssetsBanner = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, MS.Spacing.sm)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { MSDivider() }
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
                    HStack(spacing: 4) {
                        Text(workspaceVM.project.title)
                            .font(MS.Font.heading)
                            .foregroundStyle(.primary)
                            .underline(isTitleHovered)

                        if isTitleHovered {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { isTitleHovered = $0 }
            }
        }
    }

    // MARK: - Toolbar Actions

    private var toolbarActions: some View {
        HStack(spacing: MS.Spacing.sm) {
            MSBadge(
                text: statusDisplayName(workspaceVM.project.status),
                color: statusColor(workspaceVM.project.status),
                size: .small
            )
        }
    }

    private func statusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .draft:        return .secondary
        case .importing:    return .blue
        case .analyzing:    return .orange
        case .ready:        return .green
        case .exported:     return .purple
        case .configuring:  return .teal
        }
    }

    private func statusDisplayName(_ status: ProjectStatus) -> String {
        switch status {
        case .exported: return "Rendered"
        default: return status.rawValue
        }
    }
}
