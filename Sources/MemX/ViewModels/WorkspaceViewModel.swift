import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "workspace")

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

    // MARK: Motion Prompts
    var motionPrompts: [MotionPrompt] = []

    // MARK: Processing
    var processingStatus: ProcessingStatus
    var isProcessing: Bool = false

    // MARK: Storyboard
    var montagePlan: MontagePlan?
    var isGeneratingPlan: Bool = false
    var selectedSequenceItem: MontageSequenceItem? = nil

    // MARK: Title editing
    var isEditingTitle: Bool = false

    // MARK: Render
    var isRendering: Bool = false
    var renderProgress: Double = 0
    var renderProgressMessage: String = ""
    var renderedVideoURL: URL? = nil
    var renderError: String? = nil

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

        // Hydrate existing plan if present
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

        let track = SongTrack(
            title: filename,
            artist: nil,
            fileURL: url,
            durationSeconds: 0,  // filled by beatmap analysis
            fileFormat: format
        )
        songTrack = track
        project.songTrack = track
        appVM.updateProject(project)

        // Immediately analyze audio
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

            // Update song track with BPM
            if var t = songTrack {
                t.bpm = result.bpm
                t.fileURL = track.fileURL.absoluteURL  // normalize
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
        processingStatus.message = "Scoring \(assets.count) photos..."
        processingStatus.error = nil
        logger.info("Photo scoring started: \(self.assets.count) assets")

        do {
            let result = try await scoringService.scorePhotos(
                for: project,
                assets: assets
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

        } catch {
            logger.error("Photo scoring failed: \(error.localizedDescription)")
            processingStatus.error = error.localizedDescription
        }

        isProcessing = false
    }

    func generateAllMotionPrompts() async {
        guard !assets.isEmpty, !isProcessing else { return }
        isProcessing = true
        processingStatus.phase = .generatingPrompts
        processingStatus.progress = 0.55
        processingStatus.message = "Generating motion prompts..."
        processingStatus.error = nil

        // Initialize pending prompts for any assets not yet prompted
        let existingIDs = Set(motionPrompts.map(\.assetID))
        let newAssets = assets.filter { !existingIDs.contains($0.id) }
        for asset in newAssets {
            motionPrompts.append(MotionPrompt(assetID: asset.id, status: .pending))
        }

        let total = motionPrompts.count
        logger.info("Motion prompt generation started: \(total) prompts")

        for i in motionPrompts.indices {
            guard let asset = assets.first(where: { $0.id == motionPrompts[i].assetID }) else { continue }
            guard motionPrompts[i].status != .edited else { continue }  // don't overwrite user edits

            motionPrompts[i].status = .generating
            let energy = Float(beatmap?.energy(at: Double(i) / Double(max(assets.count, 1)) * (beatmap?.durationSeconds ?? 60)) ?? 0.5)
            let section = beatmap?.sections.first(where: { $0.energyAvg > Double(energy) - 0.1 })
            let name = asset.filename ?? "photo \(i + 1)"

            processingStatus.message = "Prompt \(i + 1)/\(total): \(name)"
            logger.debug("Generating prompt \(i + 1)/\(total): \(name)")

            do {
                let prompt = try await promptService.generatePrompt(
                    for: asset,
                    songEnergy: energy,
                    sectionType: section?.type
                )
                motionPrompts[i].prompt = prompt
                motionPrompts[i].motionIntensity = energy
                motionPrompts[i].status = .ready
            } catch {
                logger.warning("Prompt failed for \(name): \(error.localizedDescription)")
                motionPrompts[i].status = .pending
            }

            let progress = Double(i + 1) / Double(total)
            processingStatus.progress = 0.55 + progress * 0.22
        }

        logger.info("Motion prompts complete: \(self.readyPromptCount)/\(total) ready")
        isProcessing = false
    }

    func buildSequence() async {
        guard !assets.isEmpty, !isProcessing else { return }
        guard let bm = beatmap else { return }
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
        isProcessing = false
        isGeneratingPlan = false
    }

    /// Run the full pipeline: score photos → generate motion prompts → build sequence
    func runPipeline() async {
        guard !isProcessing else { return }
        logger.info("Full pipeline started: \(self.assets.count) assets")
        await scorePhotos()
        await generateAllMotionPrompts()
        await buildSequence()
        logger.info("Full pipeline finished")
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
        logger.info("Render started: \(plan.sequence.count) clips, song=\(song.fileURL.lastPathComponent)")

        do {
            let url = try await renderService.render(
                plan: plan,
                songURL: song.fileURL,
                assets: assets
            ) { [weak self] (prog: Double, msg: String) in
                Task { @MainActor in
                    self?.renderProgress = prog
                    self?.renderProgressMessage = msg
                }
            }
            renderedVideoURL = url
            project.status = .exported
            appVM.updateProject(project)
            logger.info("Render complete: \(url.lastPathComponent)")
        } catch {
            logger.error("Render failed: \(error.localizedDescription)")
            renderError = error.localizedDescription
        }

        isRendering = false
    }

    // MARK: - Asset Management

    func addAssets(_ newAssets: [MediaAsset]) {
        let existingIDs = Set(assets.map(\.id))
        let toAdd = newAssets.filter { !existingIDs.contains($0.id) }
        assets.append(contentsOf: toAdd)
        project.assetIDs = assets.map(\.id)
        project.updatedAt = Date()
        appVM.updateProject(project)
    }

    func removeAsset(_ asset: MediaAsset) {
        assets.removeAll { $0.id == asset.id }
        motionPrompts.removeAll { $0.assetID == asset.id }
        project.assetIDs.removeAll { $0 == asset.id }
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
        appVM.updateProject(project)
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

    // MARK: - Computed

    var totalAssetCount: Int { assets.count }
    var photoCount: Int { assets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }.count }
    var videoCount: Int { assets.filter { $0.mediaType == .video }.count }
    var hasSong: Bool { songTrack != nil }
    var hasBeatmap: Bool { beatmap != nil }
    var hasMotionPrompts: Bool { motionPrompts.contains { $0.status == .ready || $0.status == .edited } }
    var readyPromptCount: Int { motionPrompts.filter { $0.status == .ready || $0.status == .edited }.count }
    var canRunPipeline: Bool { !assets.isEmpty && !isProcessing }
    var hasPlan: Bool { montagePlan != nil }
}
