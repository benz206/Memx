import NaturalLanguage
import XCTest
@testable import MemXCore

final class SequencerSignalTests: XCTestCase {

    private let sequencer = SequencerService.shared

    private func oneHot(_ i: Int, dims: Int = 64) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[i % dims] = 1
        return v
    }

    private func scored(_ id: String, quality: Float = 0.7, emotion: Float = 0.5,
                        embedding: [Float]? = nil) -> MediaAsset {
        var a = MediaAsset(id: id, visualEmbedding: embedding, motionEnergy: 0.4)
        a.analysisScore = 0.7
        a.qualityScore = quality
        a.emotionScore = emotion
        a.noveltyScore = 0.5
        return a
    }

    private func singleSectionBeatmap(_ type: SectionType, duration: Double) -> Beatmap {
        Beatmap(
            bpm: 120, durationSeconds: duration,
            energyCurve: [EnergyPoint(time: 0, energy: 0.5), EnergyPoint(time: duration, energy: 0.5)],
            sections: [BeatSection(type: type, start: 0, end: duration, energyAvg: 0.5)],
            beats: Array(stride(from: 0.0, to: duration, by: 0.5)),
            drops: [], vocalPeaks: []
        )
    }

    func testDuplicateGroupsJoinBurstsOnly() {
        var burstB = oneHot(0)
        burstB[1] = 0.2
        let pool = [
            scored("burst-a", embedding: oneHot(0)),
            scored("burst-b", embedding: burstB),
            scored("other", embedding: oneHot(5)),
            scored("no-embedding"),
        ]
        let groups = SequencerService.duplicateGroups(for: pool)
        XCTAssertEqual(groups["burst-a"], groups["burst-b"])
        XCTAssertNotEqual(groups["burst-a"], groups["other"])
        XCTAssertNil(groups["no-embedding"])
    }

    func testBuildSequenceAvoidsRepeatingABurst() async {
        var assets = (0..<5).map { i -> MediaAsset in
            var e = oneHot(0)
            e[1] = Float(i) * 0.05
            return scored("burst-\(i)", quality: 0.95, emotion: 0.8, embedding: e)
        }
        assets += (1...30).map { scored("unique-\($0)", embedding: oneHot($0)) }

        let plan = await sequencer.buildSequence(
            title: "Bursts", settings: MontageSettings(), assets: assets,
            beatmap: singleSectionBeatmap(.verse, duration: 12), onProgress: { _, _ in })

        let unique = Set(plan.sequence.map(\.assetID))
        XCTAssertLessThan(unique.count, 30, "test needs fewer slots than unique assets")
        let burstUses = unique.filter { $0.hasPrefix("burst-") }.count
        XCTAssertEqual(burstUses, 1, "a burst of near-identical frames should appear once")
    }

    func testBuildSequencePrefersHigherQuality() async {
        let assets = [
            scored("blurry", quality: 0.2),
            scored("sharp", quality: 0.95),
        ]
        let plan = await sequencer.buildSequence(
            title: "Quality", settings: MontageSettings(), assets: assets,
            beatmap: singleSectionBeatmap(.intro, duration: 4), onProgress: { _, _ in })
        XCTAssertEqual(plan.sequence.first?.assetID, "sharp")
    }

    func testChorusOpenerGoesToHighestHighlight() async {
        var assets = (0..<12).map { scored("filler-\($0)") }
        var hero = scored("hero")
        hero.highlightScore = 1.0
        assets.insert(hero, at: 6)
        for i in assets.indices where assets[i].id != "hero" { assets[i].highlightScore = 0.2 }

        let beatmap = Beatmap(
            bpm: 120, durationSeconds: 32,
            energyCurve: [EnergyPoint(time: 0, energy: 0.4), EnergyPoint(time: 32, energy: 0.9)],
            sections: [
                BeatSection(type: .verse, start: 0, end: 16, energyAvg: 0.4),
                BeatSection(type: .chorus, start: 16, end: 32, energyAvg: 0.9),
            ],
            beats: Array(stride(from: 0.0, to: 32.0, by: 0.5)),
            drops: [], vocalPeaks: []
        )
        let plan = await sequencer.buildSequence(
            title: "Hero", settings: MontageSettings(), assets: assets,
            beatmap: beatmap, onProgress: { _, _ in })
        XCTAssertEqual(plan.sequence.first { $0.sectionType == .chorus }?.assetID, "hero")
    }

    func testIntentEmbeddingMatchesCaptionToSection() async throws {
        let sentence = NLEmbedding.sentenceEmbedding(for: .english)
        try XCTSkipIf(sentence == nil, "Sentence embedding asset unavailable")
        let svc = SemanticEmbeddingService.shared

        var party = scored("party")
        party.sceneCaption = "Friends cheering and dancing together at a birthday celebration"
        party.semanticEmbedding = svc.localEmbedding(for: party.sceneCaption!, using: sentence)
        var desk = scored("desk")
        desk.sceneCaption = "A laptop and coffee mug on an empty office desk"
        desk.semanticEmbedding = svc.localEmbedding(for: desk.sceneCaption!, using: sentence)
        var street = scored("street")
        street.sceneCaption = "A parked car on a gray street"
        street.semanticEmbedding = svc.localEmbedding(for: street.sceneCaption!, using: sentence)

        let plan = await sequencer.buildSequence(
            title: "Intent", settings: MontageSettings(), assets: [desk, street, party],
            beatmap: singleSectionBeatmap(.chorus, duration: 2), onProgress: { _, _ in })
        XCTAssertEqual(plan.sequence.first?.assetID, "party")
    }
}
