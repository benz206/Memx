import XCTest
@testable import MemXCore

final class MontagePlanModelTests: XCTestCase {

    // MARK: - MontageSequenceItem.duration

    func testSequenceItemDuration() {
        let item = MontageSequenceItem(position: 0, assetID: "a", startTime: 2.0, endTime: 5.0)
        XCTAssertEqual(item.duration, 3.0, accuracy: 0.0001)
    }

    func testSequenceItemZeroDuration() {
        let item = MontageSequenceItem(position: 0, assetID: "a", startTime: 4.0, endTime: 4.0)
        XCTAssertEqual(item.duration, 0.0, accuracy: 0.0001)
    }

    func testSequenceItemDefaultTransitions() {
        let item = MontageSequenceItem(position: 0, assetID: "a", startTime: 0, endTime: 1)
        XCTAssertEqual(item.transitionIn, .crossfade)
        XCTAssertEqual(item.transitionOut, .hardCut)
    }

    func testSequenceItemDefaults() {
        let item = MontageSequenceItem(position: 0, assetID: "x", startTime: 0, endTime: 2)
        XCTAssertEqual(item.motionIntensity, 0.5, accuracy: 0.001)
        XCTAssertFalse(item.beatAligned)
        XCTAssertEqual(item.confidenceScore, 0.8, accuracy: 0.001)
        XCTAssertEqual(item.clipOffset, 0, accuracy: 0.001)
    }

    // MARK: - TransitionType

    func testHardCutDefaultDurationIsZero() {
        XCTAssertEqual(TransitionType.hardCut.defaultDuration, 0, accuracy: 0.0001)
    }

    func testCrossfadeDefaultDuration() {
        XCTAssertEqual(TransitionType.crossfade.defaultDuration, 0.5, accuracy: 0.0001)
    }

    func testFadeFromBlackDefaultDuration() {
        XCTAssertEqual(TransitionType.fadeFromBlack.defaultDuration, 0.8, accuracy: 0.0001)
    }

    func testFlashWhiteDefaultDuration() {
        XCTAssertEqual(TransitionType.flashWhite.defaultDuration, 0.15, accuracy: 0.0001)
    }

    func testKenBurnsDriftHasLongestDuration() {
        let kenBurnsDur = TransitionType.kenBurnsDrift.defaultDuration
        for transition in TransitionType.allCases where transition != .kenBurnsDrift {
            XCTAssertLessThanOrEqual(transition.defaultDuration, kenBurnsDur,
                "\(transition) is longer than kenBurnsDrift")
        }
    }

    func testAllTransitionsHaveIcons() {
        for transition in TransitionType.allCases {
            XCTAssertFalse(transition.icon.isEmpty, "\(transition) icon is empty")
        }
    }

    // MARK: - MoodPoint

    func testMoodPointValues() {
        let point = MoodPoint(position: 0.5, valence: 0.8, energy: 0.7, label: "Chorus")
        XCTAssertEqual(point.position, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.valence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(point.energy, 0.7, accuracy: 0.0001)
        XCTAssertEqual(point.label, "Chorus")
    }

    func testMoodPointCodableRoundTrip() throws {
        let point = MoodPoint(position: 0.25, valence: 0.6, energy: 0.4, label: "Verse")
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(MoodPoint.self, from: data)
        XCTAssertEqual(decoded.position, point.position, accuracy: 0.0001)
        XCTAssertEqual(decoded.valence, point.valence, accuracy: 0.0001)
        XCTAssertEqual(decoded.energy, point.energy, accuracy: 0.0001)
        XCTAssertEqual(decoded.label, point.label)
    }

    // MARK: - ClipCandidate

    func testClipCandidateDefaultIsIncluded() {
        let candidate = ClipCandidate(assetID: "test", overallScore: 0.7)
        XCTAssertTrue(candidate.isIncluded)
    }

    func testClipCandidateDefaultFaces() {
        let candidate = ClipCandidate(assetID: "test", overallScore: 0.7)
        XCTAssertEqual(candidate.faces, 0)
    }

    func testClipCandidateRejectionReasonNilByDefault() {
        let candidate = ClipCandidate(assetID: "test", overallScore: 0.7)
        XCTAssertNil(candidate.rejectionReason)
    }

    func testClipCandidateScoresStoredCorrectly() {
        let candidate = ClipCandidate(
            assetID: "a",
            overallScore: 0.75,
            qualityScore: 0.9,
            emotionScore: 0.8,
            noveltyScore: 0.6
        )
        XCTAssertEqual(candidate.overallScore, 0.75, accuracy: 0.001)
        XCTAssertEqual(candidate.qualityScore, 0.9, accuracy: 0.001)
        XCTAssertEqual(candidate.emotionScore, 0.8, accuracy: 0.001)
        XCTAssertEqual(candidate.noveltyScore, 0.6, accuracy: 0.001)
    }

    // MARK: - MontagePlan

    func testMontagePlanTotalDurationFromLastItem() {
        let items = [
            MontageSequenceItem(position: 0, assetID: "a", startTime: 0, endTime: 3),
            MontageSequenceItem(position: 1, assetID: "b", startTime: 3, endTime: 7.5),
        ]
        let plan = MontagePlan(
            title: "Test",
            settings: MontageSettings(),
            sequence: items
        )
        XCTAssertEqual(plan.totalDuration, 7.5, accuracy: 0.0001)
    }

    func testMontagePlanEmptySequenceHasZeroDuration() {
        let plan = MontagePlan(title: "Empty", settings: MontageSettings(), sequence: [])
        XCTAssertEqual(plan.totalDuration, 0, accuracy: 0.0001)
    }

    func testMontagePlanCodableRoundTrip() throws {
        let items = [
            MontageSequenceItem(position: 0, assetID: "asset-1", startTime: 0, endTime: 2.5,
                                transitionIn: .fadeFromBlack, beatAligned: true)
        ]
        let plan = MontagePlan(title: "Codable", settings: MontageSettings(), sequence: items)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(MontagePlan.self, from: data)
        XCTAssertEqual(decoded.title, plan.title)
        XCTAssertEqual(decoded.sequence.count, plan.sequence.count)
        XCTAssertEqual(decoded.sequence.first?.assetID, "asset-1")
        XCTAssertEqual(decoded.sequence.first?.transitionIn, .fadeFromBlack)
    }
}
