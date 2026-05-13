import XCTest
@testable import MemXCore

final class SequencerServiceTests: XCTestCase {

    private let settings = MontageSettings()
    private let sequencer = SequencerService.shared

    // MARK: - buildSequence: basic output

    func testBuildSequenceReturnsNonEmptySequence() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
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
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // With only 1 passing candidate, the sequence should reuse that asset for all slots
        let usedAssetIDs = Set(plan.sequence.map(\.assetID))
        // Should only use the high-score asset (wraps around since pool is exhausted)
        XCTAssertTrue(usedAssetIDs.contains(lowAssets[0].id))
    }

    func testBuildSequenceWithNoPassingCandidatesUsesFallback() async {
        var assets = MockDataProvider.mockAssets()
        for i in 0..<assets.count {
            assets[i].analysisScore = 0.1  // all below 0.3 threshold
        }
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // When no candidates pass the threshold, the sequencer falls back to all assets
        XCTAssertFalse(plan.sequence.isEmpty)
    }

    // MARK: - buildSequence: excluded assets

    func testBuildSequenceTracksExcludedAssets() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap(duration: 30) // short beatmap → fewer slots

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
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
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertTrue(plan.moodArc.isEmpty)
    }

    func testBuildSequencePrefersSemanticFitForRequestedMood() async {
        var family = MediaAsset(id: "family", filename: "family.jpg", sceneLabels: ["people", "home"], sceneCaption: "Family smiling together indoors")
        family.analysisScore = 0.9
        family.qualityScore = 0.9
        family.emotionScore = 0.6
        family.noveltyScore = 0.5
        family.semanticSummary = "warm family home memory"

        var travel = MediaAsset(id: "travel", filename: "travel.jpg", shotType: .wide, sceneLabels: ["mountain", "sky", "road"], sceneCaption: "A wide mountain road under an open sky")
        travel.analysisScore = 0.9
        travel.qualityScore = 0.9
        travel.emotionScore = 0.6
        travel.noveltyScore = 0.5
        travel.semanticSummary = "wide travel landscape road mountain"

        let beatmap = Beatmap(
            bpm: 120,
            durationSeconds: 8,
            energyCurve: [EnergyPoint(time: 0, energy: 0.4), EnergyPoint(time: 8, energy: 0.5)],
            sections: [BeatSection(type: .intro, start: 0, end: 8, energyAvg: 0.4, cutStyle: .onBeat)],
            beats: Array(stride(from: 0.0, through: 8.0, by: 0.5)),
            drops: [],
            vocalPeaks: []
        )

        let plan = await sequencer.buildSequence(
            title: "Semantic",
            settings: MontageSettings(vibe: .travel, focus: .scenery),
            assets: [family, travel],
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        XCTAssertEqual(plan.sequence.first?.assetID, "travel")
    }

    func testBuildSequenceCutStartsStayOnBeatGrid() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap(duration: 60)

        let plan = await sequencer.buildSequence(
            title: "Beat Locked",
            settings: settings,
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for item in plan.sequence.dropFirst() {
            let nearest = beatmap.nearestBeat(to: item.startTime)
            XCTAssertEqual(item.startTime, nearest, accuracy: 0.001, "Clip \(item.position) is not beat-locked")
        }
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
            beatmap: beatmap,
            onProgress: { progress, _ in
                progressValues.append(progress)
            }
        )

        XCTAssertFalse(progressValues.isEmpty, "Expected at least one progress callback")
        // Progress should end at or near 1.0
        XCTAssertGreaterThanOrEqual(progressValues.last ?? 0, 0.9)
    }

    // MARK: - preflight

    func testPreflight_returnsShortfall_whenAssetsAreFewerThanSlots() {
        // Long beatmap with many slots, but only 2 assets → shortfall guaranteed.
        let beatmap = MockDataProvider.mockBeatmap(duration: 214)
        var assets = Array(MockDataProvider.mockAssets().prefix(2))
        for i in assets.indices { assets[i].analysisScore = 0.9 }

        let result = sequencer.preflight(settings: settings, assets: assets,
            beatmap: beatmap)

        XCTAssertTrue(result.hasShortfall, "Expected shortfall with 2 assets and long beatmap")
        XCTAssertEqual(result.availableClipCount, 2)
        XCTAssertGreaterThan(result.requiredClipCount, result.availableClipCount)
        XCTAssertEqual(result.estimatedShortfall, result.requiredClipCount - result.availableClipCount)
        XCTAssertGreaterThan(result.estimatedShortfallSeconds, 0)
    }

    func testPreflight_returnsZeroShortfall_whenAssetsExceedSlots() {
        // Very short beatmap with few slots, 20 assets → no shortfall.
        let beatmap = MockDataProvider.mockBeatmap(duration: 30)
        var assets = MockDataProvider.mockAssets()
        for i in assets.indices { assets[i].analysisScore = 0.9 }

        let result = sequencer.preflight(settings: settings, assets: assets,
            beatmap: beatmap)

        XCTAssertFalse(result.hasShortfall, "Expected no shortfall with 20 assets and 30s beatmap")
        XCTAssertEqual(result.estimatedShortfall, 0)
        XCTAssertEqual(result.estimatedShortfallSeconds, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.availableClipCount, result.requiredClipCount)
    }

    func testPreflight_fallsBackToAllAssets_whenNoneScoreAboveThreshold() {
        let beatmap = MockDataProvider.mockBeatmap(duration: 60)
        var assets = MockDataProvider.mockAssets()
        for i in assets.indices { assets[i].analysisScore = 0.1 } // all below 0.3

        let result = sequencer.preflight(settings: settings, assets: assets,
            beatmap: beatmap)

        // Pool falls back to all assets when none pass threshold.
        XCTAssertEqual(result.availableClipCount, assets.count)
    }

    // MARK: - Hook-aware sequencing

    func testBuildSequenceEmitsHookMomentsWhenBeatmapHasHooks() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmapWithHooks()

        let plan = await sequencer.buildSequence(
            title: "Hooked",
            settings: MontageSettings(),
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        let hookItems = plan.sequence.filter(\.isHookMoment)
        XCTAssertFalse(hookItems.isEmpty, "Expected at least one hook-marked clip")
    }

    func testBuildSequenceHookReturnReusesFirstOccurrenceAsset() async {
        // Reproducibility: give every asset a distinct passing score.
        var assets = MockDataProvider.mockAssets()
        for i in assets.indices { assets[i].analysisScore = 0.5 + Float(i) * 0.02 }

        let beatmap = MockDataProvider.mockBeatmapWithHooks()
        let plan = await sequencer.buildSequence(
            title: "Dejavu",
            settings: MontageSettings(),
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        // Collect hook items keyed by (repeatIndex, hookSignatureIndex-from-position).
        // hookSignatureIndex isn't on the public item but hook items within a
        // single repeatIndex are emitted in signature order, so we can match
        // by their ordinal position within each repeatIndex grouping.
        let byIndex = Dictionary(grouping: plan.sequence.filter(\.isHookMoment)) {
            $0.hookRepeatIndex ?? -1
        }
        guard let first = byIndex[0]?.sorted(by: { $0.startTime < $1.startTime }),
              let second = byIndex[1]?.sorted(by: { $0.startTime < $1.startTime }),
              !first.isEmpty, !second.isEmpty else {
            XCTFail("Expected two hook occurrences in emitted sequence")
            return
        }

        // At least one signature-beat position must reuse the same asset ID
        // between the first and second hook occurrence. (Déjà-vu check.)
        let minCount = min(first.count, second.count)
        var matchedAny = false
        for i in 0..<minCount where first[i].assetID == second[i].assetID {
            matchedAny = true
            break
        }
        XCTAssertTrue(matchedAny, "Expected the same asset at the same signature-beat position across hook repeats")
    }

    func testNostalgicVibeProducesLongerClipsThanCinematic() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmapWithHooks()

        let cinematicPlan = await sequencer.buildSequence(
            title: "C",
            settings: MontageSettings(vibe: .cinematic),
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )
        let nostalgicPlan = await sequencer.buildSequence(
            title: "N",
            settings: MontageSettings(vibe: .nostalgic),
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        let cinAvg = cinematicPlan.sequence.map(\.duration).reduce(0, +) / Double(max(cinematicPlan.sequence.count, 1))
        let nosAvg = nostalgicPlan.sequence.map(\.duration).reduce(0, +) / Double(max(nostalgicPlan.sequence.count, 1))
        XCTAssertGreaterThan(nosAvg, cinAvg, "Nostalgic avg clip length should exceed cinematic's")
    }

    // MARK: - MontageSequenceItem Codable (new fields + legacy)

    func testMontageSequenceItemRoundTripsNewFields() throws {
        let item = MontageSequenceItem(
            position: 3,
            assetID: "mock-42",
            startTime: 10,
            endTime: 14,
            transitionIn: .dissolve,
            transitionOut: .flashWhite,
            isHookMoment: true,
            isAnticipationHold: true,
            hookRepeatIndex: 2,
            gradingHint: .golden
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MontageSequenceItem.self, from: data)
        XCTAssertTrue(decoded.isHookMoment)
        XCTAssertTrue(decoded.isAnticipationHold)
        XCTAssertEqual(decoded.hookRepeatIndex, 2)
        XCTAssertEqual(decoded.gradingHint, .golden)
    }

    func testMontageSequenceItemDecodesLegacyJSON() throws {
        // Legacy storyboard without any of the new fields.
        let legacy = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "position": 0,
            "assetID": "legacy-asset",
            "startTime": 0,
            "endTime": 3,
            "transitionIn": "Crossfade",
            "transitionOut": "Hard Cut",
            "motionPrompt": "",
            "motionIntensity": 0.5,
            "beatAligned": false,
            "confidenceScore": 0.8,
            "selectionReason": "",
            "clipOffset": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MontageSequenceItem.self, from: legacy)
        XCTAssertEqual(decoded.assetID, "legacy-asset")
        XCTAssertFalse(decoded.isHookMoment)
        XCTAssertFalse(decoded.isAnticipationHold)
        XCTAssertNil(decoded.hookRepeatIndex)
        XCTAssertNil(decoded.gradingHint)
    }

    // MARK: - buildSequence: confidence scores

    func testBuildSequenceConfidenceScoresAreSet() async {
        let assets = MockDataProvider.mockAssets()
        let beatmap = MockDataProvider.mockBeatmap()

        let plan = await sequencer.buildSequence(
            title: "Test",
            settings: settings,
            assets: assets,
            beatmap: beatmap,
            onProgress: { _, _ in }
        )

        for item in plan.sequence {
            XCTAssertGreaterThan(item.confidenceScore, 0)
            XCTAssertLessThanOrEqual(item.confidenceScore, 1.0)
        }
    }
}
