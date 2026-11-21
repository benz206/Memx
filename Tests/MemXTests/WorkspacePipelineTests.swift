import XCTest
@testable import MemXCore

private struct StubError: LocalizedError {
    var errorDescription: String? { "scoring exploded" }
}

private final class StubBeatmapService: BeatmapServiceProtocol {
    func analyzeSong(at url: URL, onProgress: @escaping (Double, String) -> Void) async throws -> Beatmap {
        MockDataProvider.mockBeatmap()
    }
}

private final class StubScoringService: PhotoScoringServiceProtocol {
    var shouldFail = false
    var duringScoring: (() async -> Void)?

    func scorePhotos(for project: Project, assets: [MediaAsset], density: ScoringDensity,
                     onProgress: @escaping (Double, String) -> Void) async throws -> PhotoScoringResult {
        await duringScoring?()
        if shouldFail { throw StubError() }
        let scored = assets.map { asset -> MediaAsset in
            var a = asset
            a.analysisScore = 0.8
            a.analysisVersion = VisualSignals.analysisVersion
            return a
        }
        return PhotoScoringResult(scoredAssets: scored, candidates: [])
    }
}

private final class StubSemanticService: SemanticEnrichmentServiceProtocol {
    func enrichAssets(_ assets: [MediaAsset], onProgress: @escaping (Double, String) -> Void) async -> [MediaAsset] {
        assets
    }
}

private final class StubSequencer: SequencerServiceProtocol {
    var shortfall = 0
    private(set) var buildCount = 0

    func buildSequence(title: String, settings: MontageSettings, assets: [MediaAsset], beatmap: Beatmap,
                       onProgress: @escaping (Double, String) -> Void) async -> MontagePlan {
        buildCount += 1
        return MontagePlan(title: title, settings: settings, sequence: [])
    }

    func preflight(settings: MontageSettings, assets: [MediaAsset], beatmap: Beatmap) -> SequencerPreflight {
        SequencerPreflight(requiredClipCount: assets.count + shortfall, availableClipCount: assets.count,
                           estimatedShortfall: shortfall, estimatedShortfallSeconds: Double(shortfall) * 2)
    }
}

@MainActor
final class WorkspacePipelineTests: XCTestCase {

    private var dir: URL!
    private var scoring: StubScoringService!
    private var sequencer: StubSequencer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memx-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scoring = StubScoringService()
        sequencer = StubSequencer()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeVM(withBeatmap: Bool = true) -> WorkspaceViewModel {
        let appVM = AppViewModel(store: ProjectStore(fileURL: dir.appendingPathComponent("projects.json")))
        var project = Project(title: "Test")
        project.songTrack = SongTrack(title: "Song", fileURL: dir.appendingPathComponent("song.mp3"))
        if withBeatmap { project.beatmap = MockDataProvider.mockBeatmap() }
        let vm = WorkspaceViewModel(project: project, appVM: appVM,
                                    beatmapService: StubBeatmapService(),
                                    scoringService: scoring,
                                    semanticService: StubSemanticService(),
                                    sequencerService: sequencer)
        vm.assets = MockDataProvider.mockAssets().map { asset in
            var a = asset
            a.analysisScore = nil
            return a
        }
        return vm
    }

    func testHappyPathCompletesAndBuildsPlan() async {
        let vm = makeVM()
        await vm.runPipeline()
        guard case .completed = vm.pipelineState else { return XCTFail("\(vm.pipelineState)") }
        XCTAssertNotNil(vm.montagePlan)
        XCTAssertEqual(vm.selectedTab, .storyboard)
    }

    func testMissingBeatmapIsAnalyzedFirst() async {
        let vm = makeVM(withBeatmap: false)
        await vm.runPipeline()
        guard case .completed = vm.pipelineState else { return XCTFail("\(vm.pipelineState)") }
        XCTAssertNotNil(vm.beatmap)
    }

    func testScoringFailureStopsBeforeSequencing() async {
        scoring.shouldFail = true
        let vm = makeVM()
        await vm.runPipeline()
        XCTAssertEqual(vm.pipelineState.phase, .scoringPhotos)
        XCTAssertEqual(vm.pipelineState.errorMessage, "scoring exploded")
        XCTAssertNil(vm.montagePlan)
        XCTAssertEqual(sequencer.buildCount, 0)
        XCTAssertEqual(vm.selectedTab, .analysis)
    }

    func testShortfallPausesThenAcknowledgementBuilds() async {
        sequencer.shortfall = 5
        let vm = makeVM()
        await vm.runPipeline()
        XCTAssertEqual(vm.pipelineState, .awaitingShortfallAck(progress: vm.pipelineState.progress))
        XCTAssertNotNil(vm.clipShortfall)
        XCTAssertNil(vm.montagePlan)

        await vm.acknowledgeShortfallAndBuild()
        guard case .completed = vm.pipelineState else { return XCTFail("\(vm.pipelineState)") }
        XCTAssertEqual(sequencer.buildCount, 1)
    }

    func testAcknowledgingTheEarlyWarningWhileRunningIsHonoured() async {
        sequencer.shortfall = 5
        let vm = makeVM()
        scoring.duringScoring = { [weak vm] in
            guard let vm else { return }
            await MainActor.run { XCTAssertNotNil(vm.clipShortfall) }
            await vm.acknowledgeShortfallAndBuild()
        }
        await vm.runPipeline()
        guard case .completed = vm.pipelineState else { return XCTFail("\(vm.pipelineState)") }
        XCTAssertEqual(vm.shortfallGate, .acknowledged)
        XCTAssertEqual(sequencer.buildCount, 1)
    }

    func testDismissingAtTheGateReturnsToIdle() async {
        sequencer.shortfall = 5
        let vm = makeVM()
        await vm.runPipeline()
        vm.dismissShortfall()
        XCTAssertEqual(vm.pipelineState, .idle)
        XCTAssertEqual(vm.shortfallGate, .clear)
    }

    func testAddingAssetsResetsGateAndPipeline() async {
        sequencer.shortfall = 5
        let vm = makeVM()
        await vm.runPipeline()
        await vm.acknowledgeShortfallAndBuild()
        vm.addAssets([MediaAsset(id: "extra", mediaType: .photo)])
        XCTAssertEqual(vm.pipelineState, .idle)
        XCTAssertEqual(vm.shortfallGate, .clear)
        XCTAssertNil(vm.montagePlan)
    }

    func testLiveStatusShowsAnalyzingOnlyWhileRunning() async {
        let vm = makeVM()
        scoring.duringScoring = { [weak vm] in
            await MainActor.run { XCTAssertEqual(vm?.displayStatus, .analyzing) }
        }
        await vm.runPipeline()
        XCTAssertEqual(vm.displayStatus, .ready)
    }
}
