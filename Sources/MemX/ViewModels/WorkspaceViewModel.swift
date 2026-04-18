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

// MARK: - WorkspaceTab

enum WorkspaceTab: String, CaseIterable, Hashable {
    case song          = "Song"
    case photos        = "Photos"
    case motionPrompts = "Motion"
    case storyboard    = "Storyboard"

    var icon: String {
        switch self {
        case .song:          return "music.note.list"
        case .photos:        return "photo.stack.fill"
        case .motionPrompts: return "sparkles.rectangle.stack.fill"
        case .storyboard:    return "film.stack.fill"
        }
    }

    var stepNumber: Int {
        switch self {
        case .song:          return 1
        case .photos:        return 2
        case .motionPrompts: return 3
        case .storyboard:    return 4
        }
    }
}

// MARK: - WorkspaceViewModel

@Observable
final class WorkspaceViewModel {

    // MARK: Project
    var project: Project

    // MARK: Tabs
    var selectedTab: WorkspaceTab = .song

    // MARK: Song
    var songTrack: SongTrack?
    var beatmap: Beatmap?

    // MARK: Assets
    var assets: [MediaAsset] = []
    var isRestoringAssets: Bool = false
    var assetsFullyRestored: Bool = true

    // MARK: Motion Prompts
    var motionPrompts: [MotionPrompt] = []

    // MARK: Processing
    var processingStatus: ProcessingStatus
    var isProcessing: Bool = false

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
    private let promptService: MotionPromptServiceProtocol
    private let sequencerService: SequencerServiceProtocol
    private let renderService: VideoRenderServiceProtocol
    private let appVM: AppViewModel

    init(
        project: Project,
        appVM: AppViewModel,
        beatmapService: BeatmapServiceProtocol = BeatmapService.shared,
        scoringService: PhotoScoringServiceProtocol = PhotoScoringService.shared,
        promptService: MotionPromptServiceProtocol = MotionPromptService.shared,
        sequencerService: SequencerServiceProtocol = SequencerService.shared,
        renderService: VideoRenderServiceProtocol = VideoRenderService.shared
    ) {
        self.project = project
        self.appVM = appVM
        self.beatmapService = beatmapService
        self.scoringService = scoringService
        self.promptService = promptService
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

        selectedTab = .photos
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
                    self.processingStatus.progress = prog * 0.33
                    self.processingStatus.message = msg
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
        isProcessing = true
        processingStatus.phase = .scoringPhotos
        processingStatus.progress = 0.33
        processingStatus.message = "Scoring \(assets.count) photos (this may take a while for iCloud photos)…"
        processingStatus.error = nil
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
                    self.processingStatus.progress = 0.33 + prog * 0.22
                    self.processingStatus.message = msg
                }
            }

            let scoreMap = Dictionary(uniqueKeysWithValues: result.scoredAssets.map { ($0.id, $0) })
            assets = assets.map { scoreMap[$0.id] ?? $0 }
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

    func generateAllMotionPrompts() async {
        guard !assets.isEmpty, !isProcessing else { return }

        if !photosScoredSuccessfully {
            await scorePhotos()
            guard !isProcessing else { return }
        }

        guard !assets.isEmpty, !isProcessing else { return }
        isProcessing = true
        processingStatus.phase = .generatingPrompts
        processingStatus.progress = 0.55
        processingStatus.message = "Generating motion prompts..."
        processingStatus.error = nil

        let existingIDs = Set(motionPrompts.map(\.assetID))
        let newAssets = assets.filter { !existingIDs.contains($0.id) }
        for asset in newAssets {
            motionPrompts.append(MotionPrompt(assetID: asset.id, status: .pending))
        }

        let total = motionPrompts.count
        logger.info("Motion prompt generation started: \(total) prompts")

        let priorStatus = project.status

        // Build work queue up front so per-prompt inputs (energy, section) are
        // captured while we still hold the relevant beatmap state, then fan
        // out with bounded concurrency — on-device FM inference is the bottleneck,
        // so serial iteration would leave ~4x on the table.
        struct PromptWork {
            let index: Int
            let asset: MediaAsset
            let energy: Float
            let section: SectionType?
            let name: String
        }

        var work: [PromptWork] = []
        for i in motionPrompts.indices {
            guard motionPrompts[i].status != .edited else { continue }
            guard let asset = assets.first(where: { $0.id == motionPrompts[i].assetID }) else { continue }
            let energy = Float(beatmap?.energy(at: Double(i) / Double(max(assets.count, 1)) * (beatmap?.durationSeconds ?? 60)) ?? 0.5)
            let section = beatmap?.sections.first(where: { $0.energyAvg > Double(energy) - 0.1 })
            motionPrompts[i].status = .generating
            work.append(PromptWork(
                index: i,
                asset: asset,
                energy: energy,
                section: section?.type,
                name: asset.filename ?? "photo \(i + 1)"
            ))
        }

        let promptService = self.promptService
        let maxConcurrent = 4
        var completed = 0
        var cancelled = false

        await withTaskGroup(of: (PromptWork, Result<String, Error>).self) { group in
            var nextIdx = 0

            while nextIdx < work.count && nextIdx < maxConcurrent {
                let item = work[nextIdx]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let p = try await promptService.generatePrompt(
                            for: item.asset,
                            songEnergy: item.energy,
                            sectionType: item.section
                        )
                        return (item, .success(p))
                    } catch {
                        return (item, .failure(error))
                    }
                }
                nextIdx += 1
            }

            while let (item, result) = await group.next() {
                completed += 1
                switch result {
                case .success(let prompt):
                    motionPrompts[item.index].prompt = prompt
                    motionPrompts[item.index].motionIntensity = item.energy
                    motionPrompts[item.index].status = .ready
                case .failure(let error):
                    if error is CancellationError {
                        cancelled = true
                    } else {
                        logger.warning("Prompt failed for \(item.name): \(error.localizedDescription)")
                    }
                    motionPrompts[item.index].status = .pending
                }

                let progress = Double(completed) / Double(max(work.count, 1))
                processingStatus.progress = 0.55 + progress * 0.22
                processingStatus.message = "Prompt \(completed)/\(work.count): \(item.name)"

                if cancelled || Task.isCancelled {
                    cancelled = true
                    group.cancelAll()
                    continue
                }

                if nextIdx < work.count {
                    let next = work[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let p = try await promptService.generatePrompt(
                                for: next.asset,
                                songEnergy: next.energy,
                                sectionType: next.section
                            )
                            return (next, .success(p))
                        } catch {
                            return (next, .failure(error))
                        }
                    }
                }
            }
        }

        if cancelled {
            logger.info("Motion prompt generation cancelled")
            project.status = priorStatus
            appVM.updateProject(project)
            cancelledNotice = "Pipeline cancelled"
            isProcessing = false
            return
        }

        logger.info("Motion prompts complete: \(self.readyPromptCount)/\(total) ready")
        processingStatus.progress = 0.77
        processingStatus.message = "\(readyPromptCount)/\(total) prompts ready — build the storyboard to continue"
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
        processingStatus.progress = 0.77
        processingStatus.message = "Building sequence..."
        processingStatus.error = nil
        logger.info("Sequence building started: \(self.assets.count) assets, \(bm.sections.count) sections, \(self.motionPrompts.count) prompts")

        let plan = await sequencerService.buildSequence(
            title: project.title,
            settings: project.settings,
            assets: assets,
            motionPrompts: motionPrompts,
            beatmap: bm
        ) { [weak self] prog, msg in
            Task { @MainActor in
                self?.processingStatus.progress = 0.77 + prog * 0.23
                self?.processingStatus.message = msg
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
        selectedTab = .storyboard
        clipShortfall = nil
        isProcessing = false
        isGeneratingPlan = false
    }

    func runPipeline() async {
        guard !isProcessing else { return }
        logger.info("Full pipeline started: \(self.assets.count) assets")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                await self.scorePhotos()
                try Task.checkCancellation()
                await self.generateAllMotionPrompts()
                try Task.checkCancellation()
                await self.buildSequence()
                logger.info("Full pipeline finished")
            } catch is CancellationError {
                self.isProcessing = false
                self.cancelledNotice = "Pipeline cancelled"
            } catch {}
        }
        pipelineTask = task
        await task.value
        pipelineTask = nil
    }

    // MARK: - Video Render

    func renderVideo() async {
        guard let plan = montagePlan, !assets.isEmpty, !isRendering else { return }
        guard let song = songTrack else { return }
        guard FileManager.default.fileExists(atPath: song.fileURL.path) else {
            renderError = "Song file not found. Please re-import the audio file."
            return
        }

        isRendering = true
        renderProgress = 0
        renderProgressMessage = "Starting render…"
        renderedVideoURL = nil
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
        let restored = await PhotosLibraryService.shared.resolveAssets(for: project.assetIDs)
        assets = restored
        assetsFullyRestored = restored.count == project.assetIDs.count
        isRestoringAssets = false
    }

    func addAssets(_ newAssets: [MediaAsset]) {
        let existingIDs = Set(assets.map(\.id))
        let toAdd = newAssets.filter { !existingIDs.contains($0.id) }
        assets.append(contentsOf: toAdd)
        project.assetIDs = assets.map(\.id)
        project.updatedAt = Date()
        photosScoredSuccessfully = false
        if project.status == .draft {
            project.status = .configuring
        }
        appVM.updateProject(project)
    }

    func removeAsset(_ asset: MediaAsset) {
        assets.removeAll { $0.id == asset.id }
        motionPrompts.removeAll { $0.assetID == asset.id }
        project.assetIDs.removeAll { $0 == asset.id }
        photosScoredSuccessfully = false
        appVM.updateProject(project)
    }

    // MARK: - Motion Prompt Editing

    func updateMotionPrompt(_ prompt: MotionPrompt) {
        guard let idx = motionPrompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        motionPrompts[idx] = prompt
    }

    func setMotionPromptEdited(id: UUID, text: String) {
        guard let idx = motionPrompts.firstIndex(where: { $0.id == id }) else { return }
        motionPrompts[idx].prompt = text
        motionPrompts[idx].status = .edited
        motionPrompts[idx].isEdited = true
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
    var hasMotionPrompts: Bool { motionPrompts.contains { $0.status == .ready || $0.status == .edited } }
    var readyPromptCount: Int { motionPrompts.filter { $0.status == .ready || $0.status == .edited }.count }
    var hasScoredAssets: Bool { assets.contains { $0.analysisScore != nil } }
    var canRunPipeline: Bool { !assets.isEmpty && !isProcessing }
    var hasPlan: Bool { montagePlan != nil }
}
