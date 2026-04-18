import XCTest
@testable import MemXCore

final class SequencerServiceTests: XCTestCase {

    private let settings = MontageSettings()
    private let sequencer = SequencerService.shared

    // MARK: - buildSequence: basic output

    func testBuildSequenceReturnsNonEmptySequence() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()
        let prompts = MockDataProvider.mockMotionPrompts(for: assets)

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: prompts,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertFalse(plan.sequence.isEmpty, "Expected non-empty sequence")
    }

    func testBuildSequenceTitleIsPreserved() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Summer Montage",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertEqual(plan.title, "Summer Montage")
    }

    func testBuildSequenceSettingsArePreserved() async {
        let customSettings = MontageSettings(vibe: .hype, focus: .friends)
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: customSettings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertEqual(plan.settings.vibe, .hype)
        XCTAssertEqual(plan.settings.focus, .friends)
    }

    // MARK: - buildSequence: clip ordering

    func testBuildSequenceItemsAreInOrder() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for i in 1..<plan.sequence.count {
            XCTAssertGreaterThanOrEqual(
                plan.sequence[i].startTime,
                plan.sequence[i - 1].startTime,
                "Clip \(i) startTime is before clip \(i-1)"
            )
        }
    }

    func testBuildSequencePositionsAreSequential() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for (i, item) in plan.sequence.enumerated() {
            XCTAssertEqual(item.position, i)
        }
    }

    // MARK: - buildSequence: duration constraints

    func testBuildSequenceNeverExceedsBeatmapDuration() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for item in plan.sequence {
            XCTAssertLessThanOrEqual(
                item.endTime,
                beatmap.durationSeconds + 0.001,
                "Clip at position \(item.position) ends after beatmap duration"
            )
        }
    }

    func testBuildSequenceClipsHavePositiveDuration() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for item in plan.sequence {
            XCTAssertGreaterThan(item.duration, 0, "Clip at position \(item.position) has zero/negative duration")
        }
    }

    // MARK: - buildSequence: first clip transition

    func testBuildSequenceFirstClipFadesFromBlack() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertEqual(plan.sequence.first?.transitionIn, .fadeFromBlack,
            "First clip should always fade from black")
    }

    // MARK: - buildSequence: low-score filtering

    func testBuildSequenceFiltersLowScoreAssets() async {
        // Create assets where most have very low score (< 0.3)
        var lowAssets = MockDataProvider.mockAssets()
        for i in 0..<lowAssets.count {
            lowAssets[i].analysisScore = 0.1
        }
        // Only give the first one a passing score
        lowAssets[0].analysisScore = 0.9

        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: lowAssets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // With only 1 passing candidate, the sequence should reuse that asset for all slots
        let usedAssetIDs = Set(plan.sequence.map(\.assetID))
        // Should only use the high-score asset (wraps around since pool is exhausted)
        XCTAssertTrue(usedAssetIDs.contains(lowAssets[0].id))
    }

    func testBuildSequenceWithNoPassingCandidatesProducesEmptySequence() async {
        var assets = MockDataProvider.mockAssets()
        for i in 0..<assets.count {
            assets[i].analysisScore = 0.1  // all below 0.3 threshold
        }
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // No candidates above 0.3 means empty sequence
        XCTAssertTrue(plan.sequence.isEmpty)
    }

    // MARK: - buildSequence: excluded assets

    func testBuildSequenceTracksExcludedAssets() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap(duration: 30) // short beatmap → fewer slots

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // With only 30s, not all 20 assets will be used → some should be excluded
        // (excludedAssetIDs should not contain used asset IDs)
        let usedIDs = Set(plan.sequence.map(\.assetID))
        let excludedIDs = Set(plan.excludedAssetIDs)
        XCTAssertTrue(usedIDs.isDisjoint(with: excludedIDs),
            "Used assets should not appear in excludedAssetIDs")
    }

    // MARK: - buildSequence: mood arc

    func testBuildSequenceMoodArcNonEmpty() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertFalse(plan.moodArc.isEmpty)
    }

    func testBuildSequenceMoodArcValuesInRange() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for point in plan.moodArc {
            XCTAssertGreaterThanOrEqual(point.position, 0)
            XCTAssertLessThanOrEqual(point.position, 1.0)
            XCTAssertGreaterThanOrEqual(point.energy, 0)
            XCTAssertLessThanOrEqual(point.energy, 1.0)
        }
    }

    func testBuildSequenceMoodArcEmptyWhenNoCurve() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = Beatmap(
            bpm: 120, durationSeconds: 60,
            energyCurve: [],  // empty energy curve
            sections: [BeatSection(type: .verse, start: 0, end: 60, energyAvg: 0.5, cutStyle: .onBeat)],
            beats: Array(stride(from: 0.0, to: 60.0, by: 0.5)),
            drops: [], vocalPeaks: []
        )

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertTrue(plan.moodArc.isEmpty)
    }

    // MARK: - buildSequence: motion prompts

    func testBuildSequenceUsesMotionPrompts() async {
        let assets = MockDataProvider.mockAssets()
        let prompts = MockDataProvider.mockMotionPrompts(for: assets)
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: prompts,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // At least some clips should have non-empty motion prompts
        let nonEmptyPrompts = plan.sequence.filter { !$0.motionPrompt.isEmpty }
        XCTAssertFalse(nonEmptyPrompts.isEmpty, "Expected some clips to have motion prompts")
    }

    // MARK: - buildSequence: progress callbacks

    func testBuildSequenceCallsProgressCallback() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()
        var progressValues: [Double] = []

        let _ = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { progress, _ in
                progressValues.append(progress)
            }
        )

        XCTAssertFalse(progressValues.isEmpty, "Expected at least one progress callback")
        // Progress should end at or near 1.0
        XCTAssertGreaterThanOrEqual(progressValues.last ?? 0, 0.9)
    }

    // MARK: - buildSequence: confidence scores

    func testBuildSequenceConfidenceScoresAreSet() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            motionPrompts: [],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for item in plan.sequence {
            XCTAssertGreaterThan(item.confidenceScore, 0)
            XCTAssertLessThanOrEqual(item.confidenceScore, 1.0)
        }
    }
}
