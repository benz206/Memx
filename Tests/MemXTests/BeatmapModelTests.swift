import XCTest
@testable import MemXCore

final class BeatmapModelTests: XCTestCase {

    // MARK: - nearestBeat

    func testNearestBeatExactMatch() {
        let beats = [0.0, 0.5, 1.0, 1.5, 2.0]
        let beatmap = makeBeatmap(beats: beats)
        XCTAssertEqual(beatmap.nearestBeat(to: 1.0), 1.0, accuracy: 0.0001)
    }

    func testNearestBeatRoundsDown() {
        let beats = [0.0, 1.0, 2.0]
        let beatmap = makeBeatmap(beats: beats)
        XCTAssertEqual(beatmap.nearestBeat(to: 0.3), 0.0, accuracy: 0.0001)
    }

    func testNearestBeatRoundsUp() {
        let beats = [0.0, 1.0, 2.0]
        let beatmap = makeBeatmap(beats: beats)
        XCTAssertEqual(beatmap.nearestBeat(to: 0.7), 1.0, accuracy: 0.0001)
    }

    func testNearestBeatReturnsSelfWhenEmpty() {
        let beatmap = makeBeatmap(beats: [])
        XCTAssertEqual(beatmap.nearestBeat(to: 1.5), 1.5, accuracy: 0.0001)
    }

    func testNearestBeatSingleBeat() {
        let beatmap = makeBeatmap(beats: [3.0])
        XCTAssertEqual(beatmap.nearestBeat(to: 100.0), 3.0, accuracy: 0.0001)
    }

    // MARK: - section(at:)

    func testSectionAtTimeReturnsCorrectSection() {
        let sections = [
            BeatSection(type: .intro, start: 0, end: 15, energyAvg: 0.1),
            BeatSection(type: .verse, start: 15, end: 45, energyAvg: 0.4),
        ]
        let beatmap = makeBeatmap(sections: sections)
        XCTAssertEqual(beatmap.section(at: 5)?.type, .intro)
        XCTAssertEqual(beatmap.section(at: 20)?.type, .verse)
    }

    func testSectionAtBoundary() {
        let sections = [
            BeatSection(type: .intro, start: 0, end: 15, energyAvg: 0.1),
            BeatSection(type: .verse, start: 15, end: 45, energyAvg: 0.4),
        ]
        let beatmap = makeBeatmap(sections: sections)
        // start <= time < end, so t=15 belongs to verse
        XCTAssertEqual(beatmap.section(at: 15)?.type, .verse)
        XCTAssertEqual(beatmap.section(at: 0)?.type, .intro)
    }

    func testSectionAtReturnNilForOutOfRange() {
        let sections = [
            BeatSection(type: .verse, start: 5, end: 10, energyAvg: 0.4),
        ]
        let beatmap = makeBeatmap(sections: sections)
        XCTAssertNil(beatmap.section(at: 0))
        XCTAssertNil(beatmap.section(at: 10))
        XCTAssertNil(beatmap.section(at: 100))
    }

    // MARK: - energy(at:)

    func testEnergyAtInterpolatesBetweenPoints() {
        let curve = [
            EnergyPoint(time: 0, energy: 0.0),
            EnergyPoint(time: 10, energy: 1.0),
        ]
        let beatmap = makeBeatmap(energyCurve: curve, duration: 10)
        // Midpoint should be ~0.5
        XCTAssertEqual(beatmap.energy(at: 5), 0.5, accuracy: 0.01)
    }

    func testEnergyAtExactPoint() {
        let curve = [
            EnergyPoint(time: 0, energy: 0.2),
            EnergyPoint(time: 5, energy: 0.8),
        ]
        let beatmap = makeBeatmap(energyCurve: curve, duration: 10)
        XCTAssertEqual(beatmap.energy(at: 5), 0.8, accuracy: 0.01)
    }

    func testEnergyAtReturnsLastValuePastEnd() {
        let curve = [
            EnergyPoint(time: 0, energy: 0.3),
            EnergyPoint(time: 5, energy: 0.9),
        ]
        let beatmap = makeBeatmap(energyCurve: curve, duration: 10)
        XCTAssertEqual(beatmap.energy(at: 100), 0.9, accuracy: 0.01)
    }

    func testEnergyAtReturnsDefaultForEmptyCurve() {
        let beatmap = makeBeatmap(energyCurve: [], duration: 10)
        XCTAssertEqual(beatmap.energy(at: 5), 0.5, accuracy: 0.01)
    }

    // MARK: - BeatSection

    func testBeatSectionDuration() {
        let section = BeatSection(type: .chorus, start: 10, end: 40, energyAvg: 0.8)
        XCTAssertEqual(section.duration, 30, accuracy: 0.0001)
    }

    func testBeatSectionZeroDuration() {
        let section = BeatSection(type: .drop, start: 5, end: 5, energyAvg: 1.0)
        XCTAssertEqual(section.duration, 0, accuracy: 0.0001)
    }

    // MARK: - SectionType

    func testSectionTypeAllCasesHaveIcons() {
        for type in SectionType.allCases {
            XCTAssertFalse(type.icon.isEmpty, "\(type) icon is empty")
        }
    }

    func testSectionTypeAllCasesHaveAccentColors() {
        for type in SectionType.allCases {
            XCTAssertFalse(type.accentColor.isEmpty, "\(type) accentColor is empty")
        }
    }

    func testSectionTypeClipHoldSecondsNonEmpty() {
        for type in SectionType.allCases {
            let range = type.clipHoldSeconds
            XCTAssertLessThan(range.lowerBound, range.upperBound, "\(type) clipHoldSeconds range invalid")
        }
    }

    func testDropSectionHasShortClipHold() {
        XCTAssertLessThanOrEqual(SectionType.drop.clipHoldSeconds.upperBound, 1.5)
    }

    func testBreakdownSectionHasLongClipHold() {
        XCTAssertGreaterThanOrEqual(SectionType.breakdown.clipHoldSeconds.lowerBound, 6.0)
    }

    // MARK: - HookMoment

    func testHookAtTimeReturnsHookWhenInside() {
        var beatmap = makeBeatmap()
        beatmap.hooks = [
            HookMoment(startTime: 10, endTime: 20, repeatIndex: 0, signatureBeats: [], similarity: 0.8),
            HookMoment(startTime: 40, endTime: 55, repeatIndex: 1, signatureBeats: [], similarity: 0.8),
        ]
        XCTAssertEqual(beatmap.hook(at: 15)?.repeatIndex, 0)
        XCTAssertEqual(beatmap.hook(at: 45)?.repeatIndex, 1)
    }

    func testHookAtTimeReturnsNilOutsideRange() {
        var beatmap = makeBeatmap()
        beatmap.hooks = [
            HookMoment(startTime: 10, endTime: 20, repeatIndex: 0, signatureBeats: [], similarity: 0.8),
        ]
        XCTAssertNil(beatmap.hook(at: 5))
        XCTAssertNil(beatmap.hook(at: 25))
        // End is exclusive.
        XCTAssertNil(beatmap.hook(at: 20))
    }

    func testFinalHookStartReturnsMaxStart() {
        var beatmap = makeBeatmap()
        beatmap.hooks = [
            HookMoment(startTime: 10, endTime: 20, repeatIndex: 0, signatureBeats: [], similarity: 0.8),
            HookMoment(startTime: 45, endTime: 60, repeatIndex: 1, signatureBeats: [], similarity: 0.8),
            HookMoment(startTime: 30, endTime: 40, repeatIndex: 2, signatureBeats: [], similarity: 0.8),
        ]
        XCTAssertEqual(beatmap.finalHookStart ?? 0, 45, accuracy: 0.0001)
    }

    func testFinalHookStartNilWhenNoHooks() {
        let beatmap = makeBeatmap()
        XCTAssertNil(beatmap.finalHookStart)
    }

    func testBeatmapDecodesLegacyJSONWithoutHooks() throws {
        let legacy = """
        {
            "bpm": 120,
            "durationSeconds": 60,
            "energyCurve": [],
            "sections": [],
            "beats": [],
            "drops": [],
            "vocalPeaks": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Beatmap.self, from: legacy)
        XCTAssertEqual(decoded.hooks.count, 0)
        XCTAssertNil(decoded.finalHookStart)
    }

    func testBeatmapHooksCodableRoundTrip() throws {
        var beatmap = makeBeatmap()
        beatmap.hooks = [
            HookMoment(startTime: 10, endTime: 20, repeatIndex: 0,
                       signatureBeats: [11, 13, 15, 17], similarity: 0.82),
        ]
        let data = try JSONEncoder().encode(beatmap)
        let decoded = try JSONDecoder().decode(Beatmap.self, from: data)
        XCTAssertEqual(decoded.hooks.count, 1)
        XCTAssertEqual(decoded.hooks[0].repeatIndex, 0)
        XCTAssertEqual(decoded.hooks[0].signatureBeats, [11, 13, 15, 17])
        XCTAssertEqual(decoded.hooks[0].similarity, 0.82, accuracy: 0.001)
    }

    // MARK: - EnergyPoint

    func testEnergyPointCodableRoundTrip() throws {
        let point = EnergyPoint(time: 12.5, energy: 0.75)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(EnergyPoint.self, from: data)
        XCTAssertEqual(decoded.time, point.time, accuracy: 0.0001)
        XCTAssertEqual(decoded.energy, point.energy, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func makeBeatmap(
        beats: [Double] = [],
        sections: [BeatSection] = [],
        energyCurve: [EnergyPoint] = [],
        duration: Double = 180
    ) -> Beatmap {
        Beatmap(
            bpm: 120,
            durationSeconds: duration,
            energyCurve: energyCurve,
            sections: sections,
            beats: beats,
            drops: [],
            vocalPeaks: []
        )
    }
}
