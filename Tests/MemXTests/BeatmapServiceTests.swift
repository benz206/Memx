import XCTest
@testable import MemXCore

final class BeatmapServiceTests: XCTestCase {

    // MARK: - estimateBPM

    /// Synthetic RMS envelope: decaying spikes at every beat of the given BPM.
    private func pulseEnvelope(bpm: Double, hopRate: Double, seconds: Double) -> [Float] {
        let count = Int(hopRate * seconds)
        var env = [Float](repeating: 0.05, count: count)
        let interval = 60.0 / bpm
        var t = 0.0
        while t < seconds {
            let center = Int(t * hopRate)
            for offset in 0..<5 where center + offset < count {
                env[center + offset] = max(env[center + offset], Float(1.0 - Double(offset) * 0.2))
            }
            t += interval
        }
        return env
    }

    func testEstimateBPMRecoversTempo() {
        let hopRate = 100.0
        let env = pulseEnvelope(bpm: 128, hopRate: hopRate, seconds: 60)
        let bpm = BeatmapService.estimateBPM(envelope: env, hopRate: hopRate)
        XCTAssertEqual(bpm, 128, accuracy: 2.0)
    }

    func testEstimateBPMPrefersPerceptualOctave() {
        // A 140 BPM pulse train correlates at 70 BPM too (every other beat
        // still lines up). The tempo prior must land on 140, not 70.
        let hopRate = 100.0
        let env = pulseEnvelope(bpm: 140, hopRate: hopRate, seconds: 60)
        let bpm = BeatmapService.estimateBPM(envelope: env, hopRate: hopRate)
        XCTAssertEqual(bpm, 140, accuracy: 3.0)
    }

    func testEstimateBPMFallsBackOnTinyInput() {
        XCTAssertEqual(BeatmapService.estimateBPM(envelope: [0.1, 0.2], hopRate: 100), 120)
    }

    // MARK: - buildBeatGrid

    func testBeatGridSnapsToOnsetsAndAbsorbsTempoError() {
        // True tempo is 1% slower than the estimate. A rigid grid drifts
        // ~0.6s off by t=60s; the phase-locked grid must stay on the onsets.
        let trueInterval = 0.5 * 1.01
        let onsets = stride(from: trueInterval, to: 60.0, by: trueInterval).map {
            BeatmapService.Onset(time: $0, strength: 0.8)
        }
        let beats = BeatmapService.buildBeatGrid(bpm: 120, onsets: onsets, duration: 60)
        XCTAssertFalse(beats.isEmpty)
        for beat in beats.dropFirst(2) {
            let nearestOnset = onsets.min(by: { abs($0.time - beat) < abs($1.time - beat) })!
            XCTAssertLessThan(abs(beat - nearestOnset.time), 0.07,
                              "grid must track real onsets, not the rigid metronome")
        }
    }

    func testBeatGridWithoutOnsetsIsUniform() {
        let beats = BeatmapService.buildBeatGrid(bpm: 120, onsets: [], duration: 4)
        XCTAssertEqual(beats.count, 8)
        for (a, b) in zip(beats, beats.dropFirst()) {
            XCTAssertEqual(b - a, 0.5, accuracy: 1e-9)
        }
    }

    func testBeatGridIsStrictlyIncreasing() {
        let onsets = stride(from: 0.0, to: 30.0, by: 0.13).map {
            BeatmapService.Onset(time: $0, strength: Double.random(in: 0.3...1.0))
        }
        let beats = BeatmapService.buildBeatGrid(bpm: 120, onsets: onsets, duration: 30)
        for (a, b) in zip(beats, beats.dropFirst()) {
            XCTAssertGreaterThan(b, a)
        }
    }

    // MARK: - downbeatIndex

    func testDownbeatIndexFindsAccentedPhase() {
        let beats = stride(from: 0.0, to: 30.0, by: 0.5).map { $0 }
        // Strong onsets on beats where index % 4 == 2, weak elsewhere.
        let onsets = beats.enumerated().map { i, t in
            BeatmapService.Onset(time: t, strength: i % 4 == 2 ? 1.0 : 0.2)
        }
        XCTAssertEqual(BeatmapService.downbeatIndex(beats: beats, onsets: onsets, interval: 0.5), 2)
    }

    func testDownbeatIndexDefaultsToZeroWithoutEvidence() {
        XCTAssertEqual(BeatmapService.downbeatIndex(beats: [0, 0.5], onsets: [], interval: 0.5), 0)
    }

    // MARK: - selectPeaks

    func testSelectPeaksPicksStrongestNotEarliest() {
        let onsets = [
            BeatmapService.Onset(time: 1, strength: 0.80),
            BeatmapService.Onset(time: 2, strength: 0.90),
            BeatmapService.Onset(time: 30, strength: 0.95),
            BeatmapService.Onset(time: 31, strength: 0.76),
        ]
        let peaks = BeatmapService.selectPeaks(onsets, minStrength: 0.75, maxCount: 2, minSeparation: 5)
        XCTAssertEqual(peaks.map(\.time), [2, 30], "must include the late strong hit, in time order")
        XCTAssertEqual(peaks.map(\.intensity), [0.90, 0.95])
    }

    func testSelectPeaksEnforcesMinimumSeparation() {
        let onsets = stride(from: 0.0, to: 10.0, by: 1.0).map {
            BeatmapService.Onset(time: $0, strength: 0.8 + $0 * 0.01)
        }
        let peaks = BeatmapService.selectPeaks(onsets, minStrength: 0.5, maxCount: 10, minSeparation: 3)
        for (a, b) in zip(peaks, peaks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time - a.time, 3)
        }
    }

    // MARK: - snapSections

    func testSnapSectionsMovesBoundariesToBarStarts() {
        let sections = [
            BeatSection(type: .verse, start: 0, end: 11.3, energyAvg: 0.4),
            BeatSection(type: .chorus, start: 11.3, end: 24, energyAvg: 0.8),
        ]
        let barStarts = stride(from: 0.0, through: 24.0, by: 2.0).map { $0 }
        let snapped = BeatmapService.snapSections(sections, barStarts: barStarts)
        XCTAssertEqual(snapped[0].end, 12.0, accuracy: 1e-9)
        XCTAssertEqual(snapped[1].start, 12.0, accuracy: 1e-9)
        XCTAssertEqual(snapped[1].end, 24.0, accuracy: 1e-9, "outer edges stay put")
    }

    func testSnapSectionsNeverCollapsesASection() {
        // Nearest bar to the 2.0 boundary is 0.0, which would erase section 0.
        let sections = [
            BeatSection(type: .intro, start: 0, end: 2.0, energyAvg: 0.2),
            BeatSection(type: .verse, start: 2.0, end: 20, energyAvg: 0.5),
        ]
        let snapped = BeatmapService.snapSections(sections, barStarts: [0.0, 8.0, 16.0])
        XCTAssertEqual(snapped[0].end, 2.0, accuracy: 1e-9, "unsafe snap must be skipped")
        XCTAssertEqual(snapped[1].start, 2.0, accuracy: 1e-9)
    }

    // MARK: - Beatmap downbeat helpers

    func testBarStartsBeginAtDownbeat() {
        let beatmap = Beatmap(
            bpm: 120, durationSeconds: 4, energyCurve: [], sections: [],
            beats: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5],
            drops: [], vocalPeaks: [], downbeatIndex: 2
        )
        XCTAssertEqual(beatmap.barStarts(beatsPerBar: 4), [1.0, 3.0])
    }

    func testBeatmapDecodesLegacyJSONWithoutDownbeat() throws {
        let beatmap = Beatmap(
            bpm: 120, durationSeconds: 4, energyCurve: [], sections: [],
            beats: [0, 0.5], drops: [], vocalPeaks: []
        )
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(beatmap)) as! [String: Any]
        json.removeValue(forKey: "downbeatIndex")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Beatmap.self, from: data)
        XCTAssertEqual(decoded.downbeatIndex, 0)
    }
}
