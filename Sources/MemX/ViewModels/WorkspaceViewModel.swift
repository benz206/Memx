import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "workspace")

// MARK: - RenderLogEntry

struct RenderLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let progress: Double
    let message: String
}

// MARK: - PipelineLogEntry

struct PipelineLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let phase: ProcessingPhase
    let progress: Double
    let message: String
}

// MARK: - WorkspaceTab

enum WorkspaceTab: String, CaseIterable, Hashable {
    case song          = "Song"
    case photos        = "Photos"
    case analysis      = "Analysis"
    case storyboard    = "Storyboard"

    var icon: String {
        switch self {
        case .song:          return "music.note.list"
        case .photos:        return "photo.stack.fill"
        case .analysis:      return "sparkles.rectangle.stack"
        case .storyboard:    return "film.stack.fill"
        }
    }

    var stepNumber: Int {
        switch self {
        case .song:          return 1
        case .photos:        return 2
        case .analysis:      return 3
        case .storyboard:    return 4
        }
    }
}

enum WorkspaceStageState: Hashable {
    case complete
    case current
    case available
    case blocked
    case running
}

// MARK: - WorkspaceViewModel

@Observable
final class WorkspaceViewModel {

    // MARK: Project
    var project: Project

    // MARK: Tabs
    var selectedTab: WorkspaceTab = .song
    var stageNavigationNotice: String? = nil

    // MARK: Song
    var songTrack: SongTrack?
    var beatmap: Beatmap?

    // MARK: Assets
    var assets: [MediaAsset] = []
    var isRestoringAssets: Bool = false
    var assetsFullyRestored: Bool = true

    // MARK: Processing
    var processingStatus: ProcessingStatus
    var isProcessing: Bool = false
    var pipelineLog: [PipelineLogEntry] = []

    // MARK: Storyboard
    var montagePlan: MontagePlan?
    var isGeneratingPlan: Bool = false
    var selectedSequenceItem: MontageSequenceItem? = nil

    // MARK: Clip shortage
    var clipShortfall: SequencerPreflight? = nil
    var pendingShortfallAck: Bool = false

    // MARK: Title editing
    var isEditingTitle: Bool = false

    // MARK: Render
    var isRendering: Bool = false
    var renderProgress: Double = 0
    var renderProgressMessage: String = ""
    var renderedVideoURL: URL? = nil
    var renderError: String? = nil
    var renderLog: [RenderLogEntry] = []

    // MARK: Cancellation
    var cancelledNotice: String? = nil
    private var pipelineTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    // MARK: Dedup scoring
    private var photosScoredSuccessfully: Bool = false

    // MARK: Services
    private let beatmapService: BeatmapServiceProtocol
    private let scoringService: PhotoScoringServiceProtocol
    private let semanticService: OpenRouterServiceProtocol
    private let sequencerService: SequencerServiceProtocol
    private let renderService: VideoRenderServiceProtocol
    private let appVM: AppViewModel

    init(
        project: Project,
        appVM: AppViewModel,
        beatmapService: BeatmapServiceProtocol = BeatmapService.shared,
        scoringService: PhotoScoringServiceProtocol = PhotoScoringService.shared,
        semanticService: OpenRouterServiceProtocol = OpenRouterService.shared,
        sequencerService: SequencerServiceProtocol = SequencerService.shared,
        renderService: VideoRenderServiceProtocol = VideoRenderService.shared
    ) {
        self.project = project
        self.appVM = appVM
        self.beatmapService = beatmapService
        self.scoringService = scoringService
        self.semanticService = semanticService
        self.sequencerService = sequencerService
        self.renderService = renderService
        self.processingStatus = ProcessingStatus(projectID: project.id)
        self.songTrack = project.songTrack

        if let url = project.exportedVideoURL, FileManager.default.fileExists(atPath: url.path) {
            self.renderedVideoURL = url
        }

        if let plan = project.montagePlan {
            self.montagePlan = plan
            self.processingStatus = MockDataProvider.completedProcessingStatus(for: project)
            self.selectedTab = .storyboard
        }
        self.photosScoredSuccessfully = self.allAssetsScored
        appVM.activeWorkspaceVM = self
    }

    // MARK: - Stage Navigation

    @discardableResult
    func goToStage(_ tab: WorkspaceTab) -> Bool {
        guard canOpenStage(tab) else {
            stageNavigationNotice = blockedReason(for: tab)
            return false
        }

        selectedTab = tab
        stageNavigationNotice = nil
        return true
    }

    func goToNextStage() {
        guard let next = nextStage(after: selectedTab) else { return }
        goToStage(next)
    }

    func goToPreviousStage() {
        guard let previous = previousStage(before: selectedTab) else { return }
        selectedTab = previous
        stageNavigationNotice = nil
    }

    func dismissStageNavigationNotice() {
        stageNavigationNotice = nil
    }

    func nextStage(after tab: WorkspaceTab) -> WorkspaceTab? {
        guard let index = WorkspaceTab.allCases.firstIndex(of: tab) else { return nil }
        let nextIndex = WorkspaceTab.allCases.index(after: index)
        guard nextIndex < WorkspaceTab.allCases.endIndex else { return nil }
        return WorkspaceTab.allCases[nextIndex]
    }

    func previousStage(before tab: WorkspaceTab) -> WorkspaceTab? {
        guard let index = WorkspaceTab.allCases.firstIndex(of: tab),
              index > WorkspaceTab.allCases.startIndex
        else { return nil }
        return WorkspaceTab.allCases[WorkspaceTab.allCases.index(before: index)]
    }

    func canOpenStage(_ tab: WorkspaceTab) -> Bool {
        switch tab {
        case .song:
            return true
        case .photos:
            return hasSong
        case .analysis:
            return hasSong && !assets.isEmpty
        case .storyboard:
            return hasPlan
        }
    }

    func isStageComplete(_ tab: WorkspaceTab) -> Bool {
        switch tab {
        case .song:
            return hasSong
        case .photos:
            return !assets.isEmpty
        case .analysis:
            return hasPlan
        case .storyboard:
            return hasPlan
        }
    }

    func stageState(for tab: WorkspaceTab) -> WorkspaceStageState {
        if selectedTab == tab {
            if tab == .analysis && isProcessing { return .running }
            return .current
        }
        if isStageComplete(tab) { return .complete }
        if canOpenStage(tab) { return .available }
        return .blocked
    }

    func stageSubtitle(for tab: WorkspaceTab) -> String {
        switch tab {
        case .song:
            return hasSong ? "Track imported" : "Import audio first"
        case .photos:
            if !hasSong { return "Waiting for song" }
            return assets.isEmpty ? "Choose media" : "\(totalAssetCount) selected"
        case .analysis:
            if !hasSong { return "Waiting for song" }
            if assets.isEmpty { return "Waiting for media" }
            if isProcessing { return "Running" }
            return hasPlan ? "Storyboard built" : "Ready to run"
        case .storyboard:
            guard let plan = montagePlan else { return "Run analysis first" }
            return "\(plan.sequence.count) clips ready"
        }
    }

    func stageDetail(for tab: WorkspaceTab) -> String {
        switch tab {
        case .song:
            if let songTrack {
                return "Track ready: \(songTrack.displayTitle)"
            }
            return "Import the audio track that sets the beat, sections, and final runtime."
        case .photos:
            if !hasSong {
                return "Import a song before selecting photos and videos."
            }
            if assets.isEmpty {
                return "Choose the photos and videos that should appear in this montage."
            }
            return "\(totalAssetCount) media item\(totalAssetCount == 1 ? "" : "s") selected for analysis."
        case .analysis:
            if !hasSong {
                return "Import a song before running analysis."
            }
            if assets.isEmpty {
                return "Choose photos and videos before running analysis."
            }
            if isProcessing {
                return processingStatus.message
            }
            if hasPlan {
                return "Analysis is complete. Review the storyboard or re-run the pipeline after changes."
            }
            if allAssetsScored {
                return "Media is scored. Build the beat-matched storyboard."
            }
            return "Run the pipeline to score media and assemble the first storyboard."
        case .storyboard:
            guard let plan = montagePlan else {
                return "Run analysis before reviewing the storyboard."
            }
            let duration = formatDuration(plan.totalDuration)
            return "\(plan.sequence.count) clips over \(duration), ready for review and render."
        }
    }

    func blockedReason(for tab: WorkspaceTab) -> String {
        switch tab {
        case .song:
            return ""
        case .photos:
            return "Import a song before choosing media."
        case .analysis:
            if !hasSong { return "Import a song before running analysis." }
            return "Choose photos and videos before running analysis."
        case .storyboard:
            if !hasSong { return "Import a song before opening the storyboard." }
            if assets.isEmpty { return "Choose photos and videos before opening the storyboard." }
            return "Run the pipeline before opening the storyboard."
        }
    }

    var completedStageCount: Int {
        WorkspaceTab.allCases.filter { isStageComplete($0) }.count
    }

    var workflowProgress: Double {
        Double(completedStageCount) / Double(WorkspaceTab.allCases.count)
    }

    var nextStepMessage: String {
        if !hasSong { return "Import a song to start the project." }
        if assets.isEmpty { return "Choose photos and videos for the edit." }
        if isProcessing { return processingStatus.message }
        if !hasPlan { return "Run analysis to build the storyboard." }
        return "Review the storyboard and render the final video."
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Song Import

    func importSong(from url: URL) async {
        let filename = url.deletingPathExtension().lastPathComponent
        let format = url.pathExtension.lowercased()

        let resolvedURL = copySongToAppSupport(from: url) ?? url

        let track = SongTrack(
            title: filename,
            artist: nil,
            fileURL: resolvedURL,
            durationSeconds: 0,
            fileFormat: format
        )
        songTrack = track
        project.songTrack = track

        if project.status == .draft {
            project.status = .configuring
        }

        appVM.updateProject(project)

        await analyzeAudio(track: track)

        goToStage(.photos)
    }

    // MARK: - Pipeline Phases

    func analyzeAudio(track: SongTrack) async {
        guard !isProcessing else { return }
        isProcessing = true
        processingStatus.phase = .analyzingAudio
        processingStatus.progress = 0
        processingStatus.message = "Analyzing \(track.title)..."
        processingStatus.error = nil
        project.status = .analyzing
        appVM.updateProject(project)
        logger.info("Audio analysis started: \(track.fileURL.lastPathComponent)")

        do {
            let result = try await beatmapService.analyzeSong(at: track.fileURL) { [weak self] prog, msg in
                guard let self else { return }
                Task { @MainActor in
                    let scaled = prog * 0.20
                    self.processingStatus.progress = scaled
                    self.processingStatus.message = msg
                    self.appendPipelineLog(phase: .analyzingAudio, progress: scaled, message: msg)
                }
            }
            beatmap = result
            logger.info("Audio analysis complete: BPM=\(result.bpm, format: .fixed(precision: 1)), duration=\(result.durationSeconds, format: .fixed(precision: 1))s, sections=\(result.sections.count)")

            if var t = songTrack {
                t.bpm = result.bpm
                t.fileURL = track.fileURL.absoluteURL
                songTrack = t
                project.songTrack = t
                appVM.updateProject(project)
            }

        } catch {
            logger.error("Audio analysis failed: \(error.localizedDescription)")
            processingStatus.error = error.localizedDescription
            project.status = .draft
            appVM.updateProject(project)
        }

        isProcessing = false
    }

    func scorePhotos() async {
        guard !assets.isEmpty, !isProcessing else { return }
        if assets.allSatisfy({ $0.analysisScore != nil }) {
            photosScoredSuccessfully = true
            processingStatus.phase = .scoringPhotos
            processingStatus.progress = max(processingStatus.progress, 0.85)
            processingStatus.message = "Visual analysis already complete"
            appendPipelineLog(phase: .scoringPhotos, progress: processingStatus.progress, message: processingStatus.message)
            return
        }
        isProcessing = true
        processingStatus.phase = .scoringPhotos
        processingStatus.progress = max(processingStatus.progress, 0.20)
        processingStatus.message = "Sending \(assets.count) assets to OpenRouter for visual analysis..."
        processingStatus.error = nil
        appendPipelineLog(phase: .scoringPhotos, progress: processingStatus.progress, message: processingStatus.message)
        let density = project.settings.scoringDensity
        logger.info("Photo scoring started: \(self.assets.count) assets, density=\(density.rawValue, privacy: .public)")

        let priorStatus = project.status

        do {
            try Task.checkCancellation()

            let result = try await scoringService.scorePhotos(
                for: project,
                assets: assets,
                density: density
            ) { [weak self] prog, msg in
                guard let self else { return }
                Task { @MainActor in
                    let scaled = 0.20 + prog * 0.50
                    self.processingStatus.progress = scaled
                    self.processingStatus.message = msg
                    self.appendPipelineLog(phase: .scoringPhotos, progress: scaled, message: msg)
                }
            }

            let scoreMap = Dictionary(uniqueKeysWithValues: result.scoredAssets.map { ($0.id, $0) })
            assets = assets.map { scoreMap[$0.id] ?? $0 }
            let semanticAssets = await semanticService.enrichAssets(assets) { [weak self] prog, msg in
                guard let self else { return }
                Task { @MainActor in
                    let scaled = 0.70 + prog * 0.15
                    self.processingStatus.progress = scaled
                    self.processingStatus.message = msg
                    self.appendPipelineLog(phase: .scoringPhotos, progress: scaled, message: msg)
                }
            }
            assets = semanticAssets
            project.analyzedAssets = assets
            appVM.updateProject(project)
            let included = result.candidates.filter(\.isIncluded).count
            logger.info("Photo scoring complete: \(included)/\(result.candidates.count) candidates selected")
            photosScoredSuccessfully = true

        } catch is CancellationError {
            logger.info("Photo scoring cancelled")
            project.status = priorStatus
            appVM.updateProject(project)
            cancelledNotice = "Pipeline cancelled"
            isProcessing = false
            return
        } catch {
            logger.error("Photo scoring failed: \(error.localizedDescription)")
            processingStatus.error = error.localizedDescription
        }

        isProcessing = false
    }

    func buildSequence() async {
        guard !assets.isEmpty, !isProcessing else { return }
        guard let bm = beatmap else {
            logger.warning("buildSequence: beatmap unavailable — re-analyzing song")
            if let track = songTrack {
                await analyzeAudio(track: track)
            }
            guard let bm2 = beatmap else {
                processingStatus.error = "Song analysis is required before building the storyboard. Re-import the song."
                return
            }
            if !checkShortfall(bm: bm2) { return }
            await buildSequenceCore(bm: bm2)
            return
        }
        if !checkShortfall(bm: bm) { return }
        await buildSequenceCore(bm: bm)
    }

    /// Returns true if building should proceed; false if the user needs to
    /// acknowledge a clip shortfall first.
    private func checkShortfall(bm: Beatmap) -> Bool {
        let preflight = sequencerService.preflight(
            settings: project.settings,
            assets: assets,
            beatmap: bm
        )
        if preflight.hasShortfall && !pendingShortfallAck {
            logger.info("buildSequence: shortfall detected (\(preflight.estimatedShortfall) clips, \(preflight.estimatedShortfallSeconds, format: .fixed(precision: 1))s) — awaiting user ack")
            clipShortfall = preflight
            return false
        }
        clipShortfall = nil
        return true
    }

    func acknowledgeShortfallAndBuild() async {
        pendingShortfallAck = true
        clipShortfall = nil
        await buildSequence()
        pendingShortfallAck = false
    }

    func dismissShortfall() {
        clipShortfall = nil
    }

    private func buildSequenceCore(bm: Beatmap) async {
        isProcessing = true
        isGeneratingPlan = true
        processingStatus.phase = .sequencing
        processingStatus.progress = max(processingStatus.progress, 0.85)
        processingStatus.message = "Building sequence..."
        processingStatus.error = nil
        appendPipelineLog(phase: .sequencing, progress: processingStatus.progress, message: processingStatus.message)
        logger.info("Sequence building started: \(self.assets.count) assets, \(bm.sections.count) sections")

        let plan = await sequencerService.buildSequence(
            title: project.title,
            settings: project.settings,
            assets: assets,
            beatmap: bm
        ) { [weak self] prog, msg in
            Task { @MainActor in
                guard let self else { return }
                let scaled = 0.85 + prog * 0.15
                self.processingStatus.progress = scaled
                self.processingStatus.message = msg
                self.appendPipelineLog(phase: .sequencing, progress: scaled, message: msg)
            }
        }

        logger.info("Sequence built: \(plan.sequence.count) clips, duration=\(plan.totalDuration, format: .fixed(precision: 1))s")
        montagePlan = plan
        project.montagePlan = plan
        project.status = .ready
        processingStatus.phase = .complete
        processingStatus.progress = 1.0
        processingStatus.message = "Pipeline complete — storyboard ready"
        processingStatus.completedAt = Date()
        appVM.updateProject(project)
        goToStage(.storyboard)
        clipShortfall = nil
        isProcessing = false
        isGeneratingPlan = false
    }

    func runPipeline() async {
        guard !isProcessing else { return }
        guard hasSong else {
            stageNavigationNotice = blockedReason(for: .analysis)
            selectedTab = .song
            return
        }
        guard !assets.isEmpty else {
            stageNavigationNotice = blockedReason(for: .analysis)
            selectedTab = .photos
            return
        }

        logger.info("Full pipeline started: \(self.assets.count) assets")

        // Keep completed stages and only fill missing work. This lets users
        // jump between tabs without paying for earlier OpenRouter calls again.
        selectedSequenceItem = nil
        clipShortfall = nil
        pendingShortfallAck = false
        processingStatus = ProcessingStatus(projectID: project.id)
        photosScoredSuccessfully = allAssetsScored
        pipelineLog.removeAll()
        OpenRouterService.resetCounters()
        goToStage(.analysis)
        appendPipelineLog(phase: .idle, progress: 0, message: "Starting pipeline — \(assets.count) assets")

        // Preflight early if we already have a beatmap — surface shortfall banner
        // right away instead of waiting for buildSequence.
        if let bm = beatmap {
            let preflight = sequencerService.preflight(
                settings: project.settings,
                assets: assets,
                beatmap: bm
            )
            if preflight.hasShortfall {
                clipShortfall = preflight
            }
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                if !self.allAssetsScored {
                    await self.scorePhotos()
                }
                try Task.checkCancellation()
                await self.buildSequence()
                logger.info("Full pipeline finished")
            } catch is CancellationError {
                self.isProcessing = false
                self.cancelledNotice = "Pipeline cancelled"
                self.appendPipelineLog(phase: self.processingStatus.phase, progress: self.processingStatus.progress, message: "Pipeline cancelled")
            } catch {}
        }
        pipelineTask = task
        await task.value
        pipelineTask = nil

        // Land on the storyboard once we're truly done — but only if we
        // actually produced a plan. On cancel/error, stay on the Analysis
        // tab so the user can read the last status and re-run.
        if montagePlan != nil && processingStatus.error == nil {
            goToStage(.storyboard)
        }
    }

    // MARK: - Pipeline Log

    private func appendPipelineLog(phase: ProcessingPhase, progress: Double, message: String) {
        if let last = pipelineLog.last, last.message == message { return }
        pipelineLog.append(PipelineLogEntry(timestamp: Date(), phase: phase, progress: progress, message: message))
        if pipelineLog.count > 200 {
            pipelineLog.removeFirst(pipelineLog.count - 200)
        }
    }

    // MARK: - Video Render

    func renderVideo() async {
        guard let plan = montagePlan, !assets.isEmpty, !isRendering else { return }
        guard let song = songTrack else { return }
        guard FileManager.default.fileExists(atPath: song.fileURL.path) else {
            renderError = "Song file not found. Please re-import the audio file."
            return
        }

        // Clear any prior render on disk before starting a new one — avoids
        // leaving both old and new files around if the re-render is cancelled.
        if let existing = renderedVideoURL {
            try? FileManager.default.removeItem(at: existing)
        }
        renderedVideoURL = nil
        project.exportedVideoURL = nil
        if project.status == .exported { project.status = .ready }
        appVM.updateProject(project)

        isRendering = true
        renderProgress = 0
        renderProgressMessage = "Starting render…"
        renderError = nil
        renderLog = []
        appendRenderLog(progress: 0, message: "Starting render — \(plan.sequence.count) clips, song volume \(Int(plan.settings.songVolume * 100))%")
        logger.info("Render started: \(plan.sequence.count) clips, song=\(song.fileURL.lastPathComponent)")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()

                let tempURL = try await self.renderService.render(
                    plan: plan,
                    songURL: song.fileURL,
                    assets: self.assets
                ) { [weak self] (prog: Double, msg: String) in
                    Task { @MainActor in
                        self?.renderProgress = prog
                        self?.renderProgressMessage = msg
                        self?.appendRenderLog(progress: prog, message: msg)
                    }
                }
                let persistentURL = self.persistExport(from: tempURL)
                self.renderedVideoURL = persistentURL
                self.project.exportedVideoURL = persistentURL
                self.project.status = .exported
                self.appVM.updateProject(self.project)
                self.appendRenderLog(progress: 1.0, message: "Saved to \(persistentURL.lastPathComponent)")
                logger.info("Render complete: \(persistentURL.lastPathComponent)")
            } catch is CancellationError {
                logger.info("Render cancelled")
                self.appendRenderLog(progress: self.renderProgress, message: "Render cancelled")
                self.cancelledNotice = "Render cancelled"
            } catch {
                logger.error("Render failed: \(error.localizedDescription)")
                self.appendRenderLog(progress: self.renderProgress, message: "Error: \(error.localizedDescription)")
                self.renderError = error.localizedDescription
            }

            self.isRendering = false
        }
        renderTask = task
        await task.value
        renderTask = nil
    }

    // MARK: - Render Log

    private func appendRenderLog(progress: Double, message: String) {
        if let last = renderLog.last, last.message == message { return }
        renderLog.append(RenderLogEntry(timestamp: Date(), progress: progress, message: message))
        if renderLog.count > 200 {
            renderLog.removeFirst(renderLog.count - 200)
        }
    }

    // MARK: - Cancellation

    func cancelPipeline() {
        pipelineTask?.cancel()
        renderTask?.cancel()
    }

    var isCancellable: Bool { pipelineTask != nil || renderTask != nil }

    // MARK: - Asset Management

    func restoreAssets() async {
        guard assets.isEmpty, !project.assetIDs.isEmpty else { return }
        isRestoringAssets = true
        let resolved = await PhotosLibraryService.shared.resolveAssets(for: project.assetIDs)

        // Merge persisted analysis data back into PHAsset-resolved structs
        let analyzedMap = Dictionary(uniqueKeysWithValues: project.analyzedAssets.map { ($0.id, $0) })
        assets = resolved.map { asset in
            guard let analyzed = analyzedMap[asset.id] else { return asset }
            var merged = asset
            merged.analysisScore = analyzed.analysisScore
            merged.qualityScore = analyzed.qualityScore
            merged.emotionScore = analyzed.emotionScore
            merged.noveltyScore = analyzed.noveltyScore
            merged.eventLabel = analyzed.eventLabel
            merged.sceneLabels = analyzed.sceneLabels
            merged.sceneCaption = analyzed.sceneCaption
            merged.semanticSummary = analyzed.semanticSummary
            merged.semanticEmbedding = analyzed.semanticEmbedding
            merged.shotType = analyzed.shotType
            merged.motionVector = analyzed.motionVector
            merged.colorTemperature = analyzed.colorTemperature
            merged.faceAreaFraction = analyzed.faceAreaFraction
            merged.clipStartTime = analyzed.clipStartTime
            return merged
        }

        photosScoredSuccessfully = allAssetsScored
        assetsFullyRestored = resolved.count == project.assetIDs.count
        isRestoringAssets = false
    }

    func addAssets(_ newAssets: [MediaAsset]) {
        let existingIDs = Set(assets.map(\.id))
        let toAdd = newAssets.filter { !existingIDs.contains($0.id) }
        assets.append(contentsOf: toAdd)
        project.assetIDs = assets.map(\.id)
        project.analyzedAssets = assets
        project.updatedAt = Date()
        photosScoredSuccessfully = false
        if project.status == .draft {
            project.status = .configuring
        }
        appVM.updateProject(project)
    }

    func removeAsset(_ asset: MediaAsset) {
        assets.removeAll { $0.id == asset.id }
        project.assetIDs.removeAll { $0 == asset.id }
        project.analyzedAssets = assets
        photosScoredSuccessfully = false
        appVM.updateProject(project)
    }

    // MARK: - Settings

    func updateSettings(_ settings: MontageSettings) {
        project.settings = settings
        project.updatedAt = Date()
        if var plan = montagePlan {
            plan.settings = settings
            montagePlan = plan
            project.montagePlan = plan
        }
        appVM.updateProject(project)
    }

    func setSongVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        var settings = project.settings
        settings.songVolume = clamped
        updateSettings(settings)
    }

    func updateTitle(_ title: String) {
        guard !title.isEmpty else { return }
        project.title = title
        project.updatedAt = Date()
        appVM.updateProject(project)
    }

    // MARK: - Storyboard Editing

    func moveSequenceItem(from source: IndexSet, to destination: Int) {
        montagePlan?.sequence.move(fromOffsets: source, toOffset: destination)
        if let plan = montagePlan {
            project.montagePlan = plan
            appVM.updateProject(project)
        }
    }

    func removeSequenceItem(_ item: MontageSequenceItem) {
        montagePlan?.sequence.removeAll { $0.id == item.id }
        if let plan = montagePlan {
            project.montagePlan = plan
            appVM.updateProject(project)
        }
    }

    func updateTransition(for item: MontageSequenceItem, transitionIn: TransitionType? = nil, transitionOut: TransitionType? = nil) {
        guard let idx = montagePlan?.sequence.firstIndex(where: { $0.id == item.id }) else { return }
        if let t = transitionIn  { montagePlan?.sequence[idx].transitionIn  = t }
        if let t = transitionOut { montagePlan?.sequence[idx].transitionOut = t }
    }

    // MARK: - Export Management

    func deleteExport() {
        if let url = renderedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        renderedVideoURL = nil
        project.exportedVideoURL = nil
        if project.status == .exported { project.status = .ready }
        appVM.updateProject(project)
    }

    // MARK: - File Helpers (App Support)

    private func appSupportDirectory() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("MemX", isDirectory: true)
    }

    private func copySongToAppSupport(from url: URL) -> URL? {
        guard let base = appSupportDirectory() else { return nil }
        let dest = base.appendingPathComponent("Songs/\(project.id.uuidString)", isDirectory: true)
        let destFile = dest.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destFile.path) {
                try FileManager.default.removeItem(at: destFile)
            }
            try FileManager.default.copyItem(at: url, to: destFile)
            return destFile
        } catch {
            logger.warning("Could not copy song to App Support: \(error.localizedDescription)")
            return nil
        }
    }

    private func persistExport(from tempURL: URL) -> URL {
        guard let base = appSupportDirectory() else { return tempURL }
        let dest = base.appendingPathComponent("Exports", isDirectory: true)
        let destFile = dest.appendingPathComponent("\(project.id.uuidString).mp4")
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destFile.path) {
                try FileManager.default.removeItem(at: destFile)
            }
            try FileManager.default.moveItem(at: tempURL, to: destFile)
            return destFile
        } catch {
            logger.warning("Could not persist export to App Support: \(error.localizedDescription)")
            return tempURL
        }
    }

    // MARK: - Computed

    var totalAssetCount: Int { assets.count }
    var photoCount: Int { assets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }.count }
    var videoCount: Int { assets.filter { $0.mediaType == .video }.count }
    var hasSong: Bool { songTrack != nil }
    var hasBeatmap: Bool { beatmap != nil }
    var hasScoredAssets: Bool { assets.contains { $0.analysisScore != nil } }
    var allAssetsScored: Bool { !assets.isEmpty && assets.allSatisfy { $0.analysisScore != nil } }
    var canRunPipeline: Bool { hasSong && !assets.isEmpty && !isProcessing }
    var hasPlan: Bool { montagePlan != nil }
    var openRouterAvailable: Bool { semanticService.hasAPIKey }

    var openRouterStats: (success: Int, failure: Int, lastFailure: String?) {
        OpenRouterService.stats
    }

}
