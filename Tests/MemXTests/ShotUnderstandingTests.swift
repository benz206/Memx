import CoreGraphics
import NaturalLanguage
import XCTest
@testable import MemXCore

final class ShotUnderstandingTests: XCTestCase {

    func testMapClampsScoresAndNormalizesSubjects() {
        let log = ShotLog(caption: "  Kids jumping into a lake  ", mood: "joyful",
                          subjects: ["Kids", "Lake"], emotion: 8, energy: 14, highlight: -2)
        let u = ShotUnderstandingService.map(log)
        XCTAssertEqual(u.caption, "Kids jumping into a lake")
        XCTAssertEqual(u.subjects, ["kids", "lake"])
        XCTAssertEqual(u.emotion, 0.8, accuracy: 0.001)
        XCTAssertEqual(u.energy, 1.0, accuracy: 0.001)
        XCTAssertEqual(u.highlight, 0.0, accuracy: 0.001)
        XCTAssertEqual(u.summary, "joyful · kids · lake")
    }

    func testUnderstandingFeedsCaptionEmotionAndPhotoMotion() {
        let asset = MediaAsset(id: "p")
        let base = PhotoScoringService.shared.localAnalysis(for: asset, vision: VisionReadout(), motionSamples: nil)
        let u = ShotUnderstanding(caption: "Friends dancing at a wedding", mood: "energetic",
                                  subjects: ["friends"], emotion: 1, energy: 1, highlight: 0.9)
        let enriched = PhotoScoringService.shared.localAnalysis(for: asset, vision: VisionReadout(),
                                                                motionSamples: nil, understanding: u)
        XCTAssertEqual(enriched.sceneCaption, "Friends dancing at a wedding")
        XCTAssertEqual(enriched.semanticSummary, "energetic · friends")
        XCTAssertGreaterThan(enriched.emotionScore, base.emotionScore)
        XCTAssertGreaterThan(enriched.motionEnergy, base.motionEnergy)
        XCTAssertEqual(enriched.highlight, 0.9)
    }

    func testMeasuredVideoMotionOverridesUnderstoodEnergy() {
        let video = MediaAsset(id: "v", mediaType: .video, duration: 10)
        let u = ShotUnderstanding(caption: "", mood: "calm", subjects: [], emotion: 0, energy: 1, highlight: 0)
        let a = PhotoScoringService.shared.localAnalysis(for: video, vision: VisionReadout(),
                                                         motionSamples: [0.1, 0.1], understanding: u)
        XCTAssertEqual(a.motionEnergy, 0.1, accuracy: 0.001)
    }

    func testHighlightRaisesOverallScore() {
        let without = VisualSignals.overallScore(quality: 0.7, emotion: 0.6, novelty: 0.5)
        let hero = VisualSignals.overallScore(quality: 0.7, emotion: 0.6, novelty: 0.5, highlight: 1)
        let filler = VisualSignals.overallScore(quality: 0.7, emotion: 0.6, novelty: 0.5, highlight: 0)
        XCTAssertGreaterThan(hero, without)
        XCTAssertLessThan(filler, without)
    }

    func testSemanticInputUsesContentNotDates() {
        var asset = MediaAsset(id: "s", shotType: .wide, sceneLabels: ["beach", "ocean"],
                               sceneCaption: "Waves at sunset")
        asset.eventLabel = "Jul 12, 2024"
        asset.semanticSummary = "calm · beach"
        let text = SemanticEmbeddingService.shared.semanticInput(for: asset)
        XCTAssertTrue(text.contains("Waves at sunset"))
        XCTAssertTrue(text.contains("beach, ocean"))
        XCTAssertFalse(text.contains("2024"))
    }

    func testSemanticEmbeddingsSeparateDifferentScenes() {
        let sentence = NLEmbedding.sentenceEmbedding(for: .english)
        try? XCTSkipIf(sentence == nil, "Sentence embedding asset unavailable")
        let svc = SemanticEmbeddingService.shared
        let beach1 = svc.localEmbedding(for: "Friends laughing on a sunny beach by the ocean", using: sentence)
        let beach2 = svc.localEmbedding(for: "A group of friends playing in the waves at the beach", using: sentence)
        let office = svc.localEmbedding(for: "A spreadsheet open on a laptop at a desk", using: sentence)
        let same = VisualSignals.cosine(beach1, beach2)!
        let different = VisualSignals.cosine(beach1, office)!
        XCTAssertGreaterThan(same, different)
    }

    func testOnDeviceModelLogsAShot() async throws {
        try XCTSkipUnless(ShotUnderstandingService.isAvailable, "Apple Intelligence model unavailable")
        let side = 512
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.8, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 360, y: 380, width: 80, height: 80))

        let u = await ShotUnderstandingService.understand(context.makeImage()!, labels: ["sky", "beach"], faceCount: 0)

        let result = try XCTUnwrap(u)
        XCTAssertFalse(result.caption.isEmpty)
        XCTAssertTrue(["joyful", "tender", "calm", "nostalgic", "energetic", "dramatic", "playful", "awe"].contains(result.mood))
    }
}
