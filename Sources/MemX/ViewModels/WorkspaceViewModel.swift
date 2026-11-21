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

enum AssetRestoreState: Hashable {
    case idle
    case restoring
    case restored(missingCount: Int)
}

// MARK: - WorkspaceViewModel

@MainActor
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
    var assetRestore: AssetRestoreState = .idle

    // MARK: Processing
    var pipelineState: PipelineState = .idle
    var pipelineLog: [PipelineLogEntry] = []

    // MARK: Storyboard
    var montagePlan: MontagePlan?
    var selectedSequenceItem: MontageSequenceItem? = nil

    // MARK: Clip shortage
    var shortfallGate: ShortfallGate = .clear

    // MARK: Title editing
    var isEditingTitle: Bool = false

    // MARK: Render
    var renderState: RenderState = .idle
    var renderLog: [RenderLogEntry] = []

    // MARK: Cancellation
    private var pipelineTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    // MARK: Import
    /// The photos-stage view model, registered while ImportView is on screen
    /// so menu commands (Select All Assets, …) can reach it.
    weak var activeImportVM: ImportViewModel?

    // MARK: Services
    private let beatmapService: BeatmapServiceProtocol
    private let scoringService: PhotoScoringServiceProtocol
    private let semanticService: SemanticEnrichmentServiceProtocol
    private let sequencerService: SequencerServiceProtocol
    private let renderService: VideoRenderServiceProtocol
    private let appVM: AppViewModel

    init(
        project: Project,
        appVM: AppViewModel,
        beatmapService: BeatmapServiceProtocol = BeatmapService.shared,
        scoringService: PhotoScoringServiceProtocol = PhotoScoringService.shared,
        semanticService: SemanticEnrichmentServiceProtocol = SemanticEmbeddingService.shared,
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
        self.songTrack = project.songTrack
        self.beatmap = project.beatmap

        if let url = project.exportedVideoURL, FileManager.default.fileExists(atPath: url.path) {
            self.renderState = .finished(url)
        }

        if let plan = project.montagePlan {
            self.montagePlan = plan
            self.pipelineState = .completed(at: project.updatedAt)
            self.selectedTab = .storyboard
        }
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
                return pipelineState.message
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

    var nextStepMessage: String {
        if !hasSong { return "Import a song to start the project." }
        if assets.isEmpty { return "Choose photos and videos for the edit." }
        if isProcessing { return pipelineState.message }
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
        guard !isProcessing, !isRendering else { return }
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
        invalidateGeneratedOutputs(clearBeatmap: true)
        appVM.updateProject(project)

        await analyzeAudio(track: track)

        goToStage(.photos)
    }

    // MARK: - Pipeline

    func analyzeAudio(track: SongTrack) async {
        guard !isProcessing, !isRendering else { return }
        send(.start(.analyzingAudio, progress: 0, message: "Analyzing \(track.title)..."))
        await runPipelineTask { vm in
            try await vm.analyzeAudioStep(track: track)
            vm.send(.finishStep)
        }
    }

    func runPipeline() async {
        guard !isProcessing, !isRendering else { return }
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
        pipelineLog.removeAll()
        goToStage(.analysis)
        await run()
    }

    func buildSequence() async {
        await run()
    }

    func acknowledgeShortfallAndBuild() async {
        guard sendGate(.acknowledge) else { return }
        if !isProcessing { await buildSequence() }
    }

    func dismissShortfall() {
        guard sendGate(.dismiss) else { return }
        if case .awaitingShortfallAck = pipelineState { send(.reset) }
    }

    private func run() async {
        guard !isProcessing, !isRendering, let track = songTrack, !assets.isEmpty else { return }
        logger.info("Pipeline started: \(self.assets.count) assets")
        selectedSequenceItem = nil

        // Keep completed stages and only fill missing work. This lets users
        // jump between tabs without repaying earlier analysis work.
        let firstPhase: ProcessingPhase = beatmap == nil ? .analyzingAudio
            : allAssetsScored ? .sequencing : .scoringPhotos
        send(.start(firstPhase, progress: 0, message: "Starting pipeline — \(assets.count) assets"))
        appendPipelineLog(phase: .idle, progress: 0, message: pipelineState.message)

        // Preflight early if we already have a beatmap — surface shortfall banner
        // right away instead of waiting for buildSequence.
        if let bm = beatmap {
            sendGate(.evaluate(preflight(bm)))
        }

        await runPipelineTask { vm in
            let bm: Beatmap
            if let existing = vm.beatmap {
                bm = existing
            } else {
                bm = try await vm.analyzeAudioStep(track: track)
            }
            if vm.allAssetsScored {
                vm.report(.scoringPhotos, progress: 0.85, message: "Visual analysis already complete")
            } else {
                try await vm.scoreStep()
            }
            try await vm.sequenceStep(beatmap: bm)
        }

        // Land on the storyboard once we're truly done — but only if we
        // actually produced a plan. On cancel/error, stay on the Analysis
        // tab so the user can read the last status and re-run.
        if case .completed = pipelineState {
            goToStage(.storyboard)
        }
    }

    private func runPipelineTask(_ work: @escaping @MainActor (WorkspaceViewModel) async throws -> Void) async {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch is CancellationError {
                logger.info("Pipeline cancelled at \(self.pipelineState.phase.rawValue, privacy: .public)")
                self.send(.cancel)
                self.appendPipelineLog(phase: self.pipelineState.phase, progress: self.pipelineState.progress, message: self.pipelineState.message)
            } catch {
                logger.error("Pipeline failed at \(self.pipelineState.phase.rawValue, privacy: .public): \(error.localizedDescription)")
                self.send(.fail(error.localizedDescription))
                self.appendPipelineLog(phase: self.pipelineState.phase, progress: self.pipelineState.progress, message: "Error: \(error.localizedDescription)")
            }
        }
        pipelineTask = task
        await task.value
        pipelineTask = nil
    }

    @discardableResult
    private func analyzeAudioStep(track: SongTrack) async throws -> Beatmap {
        report(.analyzingAudio, progress: 0, message: "Analyzing \(track.title)...")
        logger.info("Audio analysis started: \(track.fileURL.lastPathComponent)")

        let result = try await beatmapService.analyzeSong(at: track.fileURL) { [weak self] prog, msg in
            Task { @MainActor in
                self?.report(.analyzingAudio, progress: prog * 0.20, message: msg)
            }
        }
        beatmap = result
        project.beatmap = result
        logger.info("Audio analysis complete: BPM=\(result.bpm, format: .fixed(precision: 1)), duration=\(result.durationSeconds, format: .fixed(precision: 1))s, sections=\(result.sections.count)")

        if var t = songTrack {
            t.bpm = result.bpm
            t.fileURL = track.fileURL.absoluteURL
            songTrack = t
            project.songTrack = t
            appVM.updateProject(project)
        }
        try Task.checkCancellation()
        return result
    }

    private func scoreStep() async throws {
        report(.scoringPhotos, progress: 0.20, message: "Analyzing \(assets.count) assets on-device...")
        let density = project.settings.scoringDensity
        logger.info("Photo scoring started: \(self.assets.count) assets, density=\(density.rawValue, privacy: .public)")

        let result = try await scoringService.scorePhotos(
            for: project,
            assets: assets,
            density: density
        ) { [weak self] prog, msg in
            Task { @MainActor in
                self?.report(.scoringPhotos, progress: 0.20 + prog * 0.50, message: msg)
            }
        }

        let scoreMap = Dictionary(uniqueKeysWithValues: result.scoredAssets.map { ($0.id, $0) })
        assets = assets.map { scoreMap[$0.id] ?? $0 }
        let semanticAssets = await semanticService.enrichAssets(assets) { [weak self] prog, msg in
            Task { @MainActor in
                self?.report(.scoringPhotos, progress: 0.70 + prog * 0.15, message: msg)
            }
        }
        assets = semanticAssets
        project.analyzedAssets = assets
        appVM.updateProject(project)
        let included = result.candidates.filter(\.isIncluded).count
        logger.info("Photo scoring complete: \(included)/\(result.candidates.count) candidates selected")
        try Task.checkCancellation()
    }

    private func sequenceStep(beatmap bm: Beatmap) async throws {
        let preflight = preflight(bm)
        sendGate(.evaluate(preflight))
        if shortfallGate.blocksBuild {
            logger.info("buildSequence: shortfall detected (\(preflight.estimatedShortfall) clips, \(preflight.estimatedShortfallSeconds, format: .fixed(precision: 1))s) — awaiting user ack")
            send(.awaitShortfallAck)
            appendPipelineLog(phase: .sequencing, progress: pipelineState.progress, message: pipelineState.message)
            return
        }

        report(.sequencing, progress: 0.85, message: "Building sequence...")
        logger.info("Sequence building started: \(self.assets.count) assets, \(bm.sections.count) sections")

        let plan = await sequencerService.buildSequence(
            title: project.title,
            settings: project.settings,
            assets: assets,
            beatmap: bm
        ) { [weak self] prog, msg in
            Task { @MainActor in
                self?.report(.sequencing, progress: 0.85 + prog * 0.15, message: msg)
            }
        }
        try Task.checkCancellation()

        logger.info("Sequence built: \(plan.sequence.count) clips, duration=\(plan.totalDuration, format: .fixed(precision: 1))s")
        montagePlan = plan
        project.montagePlan = plan
        appVM.updateProject(project)
        send(.complete(at: Date()))
        appendPipelineLog(phase: .complete, progress: 1, message: pipelineState.message)
    }

    private func preflight(_ bm: Beatmap) -> SequencerPreflight {
        sequencerService.preflight(settings: project.settings, assets: assets, beatmap: bm)
    }

    // MARK: - State Transitions

    @discardableResult
    private func send(_ event: PipelineEvent) -> Bool {
        guard let next = pipelineState.next(on: event) else {
            logger.debug("Pipeline ignored \(String(describing: event), privacy: .public) in \(String(describing: self.pipelineState), privacy: .public)")
            return false
        }
        pipelineState = next
        return true
    }

    @discardableResult
    private func sendGate(_ event: ShortfallGateEvent) -> Bool {
        guard let next = shortfallGate.next(on: event) else {
            logger.debug("Shortfall gate ignored \(String(describing: event), privacy: .public) in \(String(describing: self.shortfallGate), privacy: .public)")
            return false
        }
        shortfallGate = next
        return true
    }

    private func report(_ phase: ProcessingPhase, progress: Double, message: String) {
        guard send(.progress(phase, progress: progress, message: message)) else { return }
        appendPipelineLog(phase: phase, progress: progress, message: message)
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
        guard let plan = montagePlan, !assets.isEmpty, !isRendering, !isProcessing else { return }
        guard let song = songTrack else { return }
        guard sendRender(.start("Starting render…")) else { return }

        // Clear any prior render on disk before starting a new one — avoids
        // leaving both old and new files around if the re-render is cancelled.
        if let existing = project.exportedVideoURL {
            try? FileManager.default.removeItem(at: existing)
        }
        project.exportedVideoURL = nil
        appVM.updateProject(project)

        renderLog = []
        appendRenderLog(progress: 0, message: "Starting render — \(plan.sequence.count) clips, song volume \(Int(plan.settings.songVolume * 100))%")
        guard FileManager.default.fileExists(atPath: song.fileURL.path) else {
            sendRender(.fail("Song file not found. Please re-import the audio file."))
            return
        }
        logger.info("Render started: \(plan.sequence.count) clips, song=\(song.fileURL.lastPathComponent)")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()

                let tempURL = try await self.renderService.render(
                    plan: plan,
                    songURL: song.fileURL,
                    assets: self.assets,
                    beatmap: self.beatmap
                ) { [weak self] (prog: Double, msg: String) in
                    Task { @MainActor in
                        self?.reportRender(progress: prog, message: msg)
                    }
                }
                let persistentURL = self.persistExport(from: tempURL)
                self.project.exportedVideoURL = persistentURL
                self.appVM.updateProject(self.project)
                self.sendRender(.finish(persistentURL))
                self.appendRenderLog(progress: 1.0, message: "Saved to \(persistentURL.lastPathComponent)")
                logger.info("Render complete: \(persistentURL.lastPathComponent)")
            } catch is CancellationError {
                logger.info("Render cancelled")
                self.appendRenderLog(progress: self.renderProgress, message: "Render cancelled")
                self.sendRender(.cancel)
            } catch {
                logger.error("Render failed: \(error.localizedDescription)")
                self.appendRenderLog(progress: self.renderProgress, message: "Error: \(error.localizedDescription)")
                self.sendRender(.fail(error.localizedDescription))
            }
        }
        renderTask = task
        await task.value
        renderTask = nil
    }

    @discardableResult
    private func sendRender(_ event: RenderEvent) -> Bool {
        guard let next = renderState.next(on: event) else {
            logger.debug("Render ignored \(String(describing: event), privacy: .public) in \(String(describing: self.renderState), privacy: .public)")
            return false
        }
        renderState = next
        return true
    }

    private func reportRender(progress: Double, message: String) {
        guard sendRender(.progress(progress, message)) else { return }
        appendRenderLog(progress: progress, message: message)
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

    private func invalidateGeneratedOutputs(clearBeatmap: Bool = false) {
        if clearBeatmap {
            beatmap = nil
            project.beatmap = nil
        }

        montagePlan = nil
        selectedSequenceItem = nil
        project.montagePlan = nil
        project.exportedVideoURL = nil
        sendGate(.reset)
        sendRender(.reset)
        send(.reset)

        if selectedTab == .storyboard {
            if hasSong && !assets.isEmpty {
                selectedTab = .analysis
            } else if hasSong {
                selectedTab = .photos
            } else {
                selectedTab = .song
            }
        }
    }

    func restoreAssets() async {
        guard assetRestore != .restoring, assets.isEmpty, !project.assetIDs.isEmpty else { return }
        assetRestore = .restoring
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
            merged.visualEmbedding = analyzed.visualEmbedding
            merged.motionEnergy = analyzed.motionEnergy
            merged.shotType = analyzed.shotType
            merged.colorTemperature = analyzed.colorTemperature
            merged.faceAreaFraction = analyzed.faceAreaFraction
            merged.clipStartTime = analyzed.clipStartTime
            merged.motionSamples = analyzed.motionSamples
            merged.analysisVersion = analyzed.analysisVersion
            merged.isUtility = analyzed.isUtility
            merged.faceCount = analyzed.faceCount
            merged.focusPoint = analyzed.focusPoint
            merged.mood = analyzed.mood
            merged.highlightScore = analyzed.highlightScore
            return merged
        }

        assetRestore = .restored(missingCount: project.assetIDs.count - resolved.count)
    }

    func addAssets(_ newAssets: [MediaAsset]) {
        let existingIDs = Set(assets.map(\.id))
        let toAdd = newAssets.filter { !existingIDs.contains($0.id) }
        guard !toAdd.isEmpty else { return }

        assets.append(contentsOf: toAdd)
        project.assetIDs = assets.map(\.id)
        project.analyzedAssets = assets
        project.updatedAt = Date()
        invalidateGeneratedOutputs()
        appVM.updateProject(project)
    }

    func removeAsset(_ asset: MediaAsset) {
        guard assets.contains(where: { $0.id == asset.id }) else { return }

        assets.removeAll { $0.id == asset.id }
        project.assetIDs.removeAll { $0 == asset.id }
        project.analyzedAssets = assets
        invalidateGeneratedOutputs()
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
        sendRender(.reset)
        project.exportedVideoURL = nil
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
    var allAssetsScored: Bool {
        !assets.isEmpty && assets.allSatisfy {
            $0.analysisScore != nil && $0.analysisVersion == VisualSignals.analysisVersion
        }
    }
    var isRestoringAssets: Bool { assetRestore == .restoring }
    var assetsFullyRestored: Bool {
        if case let .restored(missingCount) = assetRestore { return missingCount == 0 }
        return true
    }
    var isProcessing: Bool { pipelineState.isRunning }
    var isRendering: Bool { renderState.isRendering }
    var renderProgress: Double { renderState.progress }
    var renderProgressMessage: String { renderState.message }
    var renderedVideoURL: URL? { renderState.videoURL }
    var renderError: String? { renderState.errorMessage }
    var isGeneratingPlan: Bool { isProcessing && pipelineState.phase == .sequencing }
    var clipShortfall: SequencerPreflight? { shortfallGate.warning }
    var canRunPipeline: Bool { hasSong && !assets.isEmpty && !isProcessing && !isRendering }
    var hasPlan: Bool { montagePlan != nil }
    var displayStatus: ProjectStatus { isProcessing ? .analyzing : project.status }
}
