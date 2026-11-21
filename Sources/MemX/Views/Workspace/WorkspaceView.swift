import SwiftUI
import Photos

struct WorkspaceView: View {
    let project: Project
    @Environment(AppViewModel.self) private var appVM
    @State private var workspaceVM: WorkspaceViewModel
    @State private var showMissingAssetsBanner = false
    @State private var showLeaveConfirm = false
    @State private var isTitleHovered = false
    @FocusState private var titleFieldFocused: Bool

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
                .help("Back to Projects (⌘[)")
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
        List(selection: Binding(
            get: { Optional(workspaceVM.selectedTab) },
            set: { if let tab = $0 { workspaceVM.goToStage(tab) } }
        )) {
            Section("Stages") {
                ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                    stageSidebarRow(tab)
                        .tag(tab)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(workspaceVM.project.title)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private func stageSidebarRow(_ tab: WorkspaceTab) -> some View {
        let state = workspaceVM.stageState(for: tab)

        HStack(spacing: MS.Spacing.sm) {
            Label {
                Text(tab.rawValue)
                    .font(MS.Font.body)
            } icon: {
                Image(systemName: tab.icon)
            }
            Spacer(minLength: 0)
            stepIcon(for: tab)
        }
        .opacity(state == .blocked ? 0.5 : 1)
        .help("\(tab.rawValue) (⌘\(tab.stepNumber))")
    }

    @ViewBuilder
    private func stepIcon(for tab: WorkspaceTab) -> some View {
        switch workspaceVM.stageState(for: tab) {
        case .complete:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MSColor.success)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .blocked:
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(MSColor.inkFaint)
        case .current, .available:
            Text("\(tab.stepNumber)")
                .font(MS.Font.mono)
                .foregroundStyle(MSColor.inkFaint)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Project").msEyebrow()
                    .padding(.bottom, 1)
                MSStatRow(label: "Song", value: workspaceVM.songTrack?.displayTitle ?? "None")
                if let bpm = workspaceVM.songTrack?.bpm {
                    MSStatRow(label: "Tempo", value: "\(Int(bpm)) BPM")
                }
                MSStatRow(label: "Photos", value: "\(workspaceVM.photoCount)")
                MSStatRow(label: "Videos", value: "\(workspaceVM.videoCount)")
            }

            if workspaceVM.hasSong && !workspaceVM.assets.isEmpty {
                Group {
                    if workspaceVM.isProcessing {
                        // While processing, show only Cancel — cleaner than a
                        // loading primary + cancel stacked together.
                        if workspaceVM.isCancellable {
                            Button { workspaceVM.cancelPipeline() } label: {
                                MSButtonLabel(title: "Cancel", icon: "xmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.ms(.danger))
                        }
                    } else if workspaceVM.hasPlan {
                        Button { Task { await workspaceVM.runPipeline() } } label: {
                            MSButtonLabel(title: "Re-run Pipeline", icon: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.ms(.secondary))
                        .disabled(workspaceVM.isRendering)
                        .help("Run Pipeline (⌘R)")
                    } else {
                        Button { Task { await workspaceVM.runPipeline() } } label: {
                            MSButtonLabel(title: "Run Pipeline", icon: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.ms(.primary))
                        .disabled(!workspaceVM.canRunPipeline)
                        .help("Run Pipeline (⌘R)")
                    }
                }
                .padding(.top, MS.Spacing.xs)
            }
        }
        .padding(12)
        .background(MSColor.surface, in: RoundedRectangle(cornerRadius: MS.Radius.md + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MS.Radius.md + 2, style: .continuous)
                .strokeBorder(MSColor.line, lineWidth: 1)
        )
        .padding(MS.Spacing.sm)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            let photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if photosStatus == .denied || photosStatus == .restricted {
                photosAccessBanner
            }

            if workspaceVM.isRestoringAssets {
                HStack(spacing: MS.Spacing.sm) {
                    ProgressView().controlSize(.mini)
                    Text("Loading media…")
                        .font(MS.Font.caption)
                        .foregroundStyle(MSColor.inkMuted)
                    Spacer()
                }
                .padding(.horizontal, MS.Spacing.md)
                .frame(height: 32)
                .background(MSColor.surface)
                .overlay(alignment: .bottom) { MSDivider() }
            }

            if showMissingAssetsBanner {
                missingAssetsBanner
            }

            if let shortfall = workspaceVM.clipShortfall {
                clipShortfallBanner(shortfall)
            }

            if let notice = workspaceVM.stageNavigationNotice {
                stageNavigationBanner(notice)
            }

            stageOverviewBar

            Group {
                switch workspaceVM.selectedTab {
                case .song:
                    SongImportView()
                case .photos:
                    ImportView()
                case .analysis:
                    PipelineRunView()
                case .storyboard:
                    StoryboardView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MSColor.canvas)
        .environment(workspaceVM)
    }

    private var stageOverviewBar: some View {
        HStack(alignment: .center, spacing: MS.Spacing.sm) {
            Text("Step \(workspaceVM.selectedTab.stepNumber) of \(WorkspaceTab.allCases.count)")
                .font(MS.Font.mono)
                .foregroundStyle(MSColor.inkFaint)
            Text(workspaceVM.stageDetail(for: workspaceVM.selectedTab))
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: MS.Spacing.md)

            if let previous = workspaceVM.previousStage(before: workspaceVM.selectedTab) {
                MSIconButton(icon: "chevron.left", help: "Previous stage (⇧⌘[)") {
                    workspaceVM.goToStage(previous)
                }
            }

            if let next = workspaceVM.nextStage(after: workspaceVM.selectedTab) {
                MSIconButton(icon: "chevron.right", help: "Next stage (⇧⌘])") {
                    workspaceVM.goToStage(next)
                }
                .disabled(!workspaceVM.canOpenStage(next))
            }
        }
        .padding(.horizontal, MS.Spacing.md)
        .frame(height: 36)
        .background(MSColor.surface)
        .overlay(alignment: .bottom) { MSDivider() }
    }

    /// Shared chrome for the workspace warning banners: orange icon, caption
    /// message, then banner-specific trailing controls.
    private func warningBanner<Trailing: View>(
        icon: String,
        message: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: MS.Spacing.sm + 2) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MSColor.warning)
            Text(message)
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.ink)
                .lineLimit(2)
            Spacer()
            trailing()
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, 9)
        .background(MSColor.warning.opacity(0.08))
        .overlay(alignment: .bottom) { MSColor.warning.opacity(0.2).frame(height: 1) }
    }

    private func bannerLinkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.ms(.secondary, size: .small))
    }

    private func bannerDismissButton(action: @escaping () -> Void) -> some View {
        MSIconButton(icon: "xmark", help: "Dismiss", action: action)
    }

    private func stageNavigationBanner(_ message: String) -> some View {
        warningBanner(icon: "lock.fill", message: message) {
            bannerDismissButton { workspaceVM.dismissStageNavigationNotice() }
        }
    }

    private var photosAccessBanner: some View {
        warningBanner(
            icon: "exclamationmark.triangle.fill",
            message: "Photos access is denied. Grant access to load your library."
        ) {
            bannerLinkButton("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
        }
    }

    private var missingAssetsBanner: some View {
        warningBanner(
            icon: "photo.badge.exclamationmark.fill",
            message: "Some assets from this project are no longer available. Add media to continue."
        ) {
            bannerLinkButton("Pick Media") {
                workspaceVM.goToStage(.photos)
                showMissingAssetsBanner = false
            }
            bannerDismissButton { showMissingAssetsBanner = false }
        }
    }

    private func clipShortfallBanner(_ shortfall: SequencerPreflight) -> some View {
        let seconds = Int(shortfall.estimatedShortfallSeconds.rounded())
        let timeStr = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return warningBanner(
            icon: "photo.badge.exclamationmark.fill",
            message: "Not enough photos to fill the song. Need ~\(shortfall.estimatedShortfall) more clips (\(timeStr) of the song would repeat)."
        ) {
            bannerLinkButton("Add Photos") {
                workspaceVM.goToStage(.photos)
            }
            bannerLinkButton("Build Anyway") {
                Task { await workspaceVM.acknowledgeShortfallAndBuild() }
            }
            bannerDismissButton { workspaceVM.dismissShortfall() }
        }
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
                    .focused($titleFieldFocused)
                    .onSubmit {
                        workspaceVM.updateTitle(workspaceVM.project.title)
                        workspaceVM.isEditingTitle = false
                    }
                    .onExitCommand { workspaceVM.isEditingTitle = false }
                    .onAppear { titleFieldFocused = true }
                    .onChange(of: workspaceVM.isEditingTitle) { _, editing in
                        if editing { titleFieldFocused = true }
                    }
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
                text: workspaceVM.displayStatus.displayName,
                color: workspaceVM.displayStatus.displayColor,
                size: .small,
                showsDot: true
            )
        }
    }

}
