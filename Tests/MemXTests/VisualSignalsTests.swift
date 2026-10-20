import CoreGraphics
import XCTest
@testable import MemXCore

final class VisualSignalsTests: XCTestCase {

    func testUtilityImagesAreFlooredBelowPoolThreshold() {
        let q = VisualSignals.qualityScore(aesthetic: 0.8, isUtility: true, bestFaceQuality: nil, isFavorite: true)
        XCTAssertLessThan(q, 0.3)
    }

    func testAestheticsDriveQuality() {
        let good = VisualSignals.qualityScore(aesthetic: 0.7, isUtility: false, bestFaceQuality: nil, isFavorite: false)
        let poor = VisualSignals.qualityScore(aesthetic: -0.4, isUtility: false, bestFaceQuality: nil, isFavorite: false)
        XCTAssertGreaterThan(good, poor + 0.4)
        XCTAssertLessThanOrEqual(good, 1)
        XCTAssertGreaterThanOrEqual(poor, 0)
    }

    func testFavoriteRaisesQuality() {
        let base = VisualSignals.qualityScore(aesthetic: 0.2, isUtility: false, bestFaceQuality: nil, isFavorite: false)
        let fav = VisualSignals.qualityScore(aesthetic: 0.2, isUtility: false, bestFaceQuality: nil, isFavorite: true)
        XCTAssertGreaterThan(fav, base)
    }

    func testUtilityDetectedFromTopLabels() {
        XCTAssertTrue(VisualSignals.isUtility(identifiers: ["screenshot", "text"], aestheticsSaysUtility: false))
        XCTAssertTrue(VisualSignals.isUtility(identifiers: ["beach"], aestheticsSaysUtility: true))
        XCTAssertFalse(VisualSignals.isUtility(identifiers: ["beach", "people"], aestheticsSaysUtility: false))
    }

    func testPeopleAndCelebrationsScoreMoreEmotional() {
        let empty = VisualSignals.emotionScore(faceCount: 0, identifiers: ["structure"], isFavorite: false)
        let party = VisualSignals.emotionScore(faceCount: 4, identifiers: ["celebration", "birthday_cake"], isFavorite: false)
        XCTAssertGreaterThan(party, empty + 0.3)
    }

    func testActionLabelsRaisePhotoMotion() {
        let still = VisualSignals.photoMotionEnergy(faceCount: 0, identifiers: ["flower"])
        let action = VisualSignals.photoMotionEnergy(faceCount: 2, identifiers: ["surfing", "watersport"])
        XCTAssertGreaterThan(action, still + 0.3)
    }

    func testShotTypeFromFacesAndLabels() {
        XCTAssertEqual(VisualSignals.shotType(faceCount: 1, largestFaceArea: 0.15, identifiers: [], isVideo: false, motionEnergy: nil), .closeUp)
        XCTAssertEqual(VisualSignals.shotType(faceCount: 5, largestFaceArea: 0.01, identifiers: [], isVideo: false, motionEnergy: nil), .group)
        XCTAssertEqual(VisualSignals.shotType(faceCount: 1, largestFaceArea: 0.02, identifiers: [], isVideo: false, motionEnergy: nil), .medium)
        XCTAssertEqual(VisualSignals.shotType(faceCount: 0, largestFaceArea: 0, identifiers: ["outdoor", "mountain"], isVideo: false, motionEnergy: nil), .wide)
        XCTAssertEqual(VisualSignals.shotType(faceCount: 0, largestFaceArea: 0, identifiers: ["food", "cake"], isVideo: false, motionEnergy: nil), .detail)
        XCTAssertEqual(VisualSignals.shotType(faceCount: 0, largestFaceArea: 0, identifiers: [], isVideo: true, motionEnergy: 0.8), .motion)
    }

    func testDisplayLabelsAreReadableAndDeduplicated() {
        XCTAssertEqual(VisualSignals.displayLabels(["sunset_sunrise", "beach", "beach"]), ["sunset sunrise", "beach"])
    }

    func testNoveltyLowForNearDuplicatesHighForUnique() {
        let a: [Float] = [1, 0, 0]
        let aBurst: [Float] = [0.99, 0.1, 0]
        let unrelated: [Float] = [0, 0, 1]
        let scores = VisualSignals.noveltyScores([a, aBurst, unrelated, nil])
        XCTAssertLessThan(scores[0]!, 0.1)
        XCTAssertLessThan(scores[1]!, 0.1)
        XCTAssertGreaterThan(scores[2]!, 0.9)
        XCTAssertNil(scores[3])
    }

    func testEventsSplitOnTimeGaps() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let dates: [Date?] = [
            base,
            base.addingTimeInterval(1800),
            base.addingTimeInterval(1800 + 5 * 3600),
            nil,
        ]
        let labels = VisualSignals.eventLabels(dates: dates, locations: [nil, nil, nil, nil])
        XCTAssertEqual(labels[0], labels[1])
        XCTAssertNotEqual(labels[1], labels[2])
        XCTAssertNil(labels[3])
    }

    func testEventsSplitOnLocationJumps() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let dates: [Date?] = [base, base.addingTimeInterval(600)]
        let sf = AssetLocation(latitude: 37.77, longitude: -122.42)
        let la = AssetLocation(latitude: 34.05, longitude: -118.24)
        let labels = VisualSignals.eventLabels(dates: dates, locations: [sf, la])
        XCTAssertNotEqual(labels[0], labels[1])
    }

    func testPoolSignalsUseMeasuredNoveltyAndDropUtility() {
        var keeper = MediaAsset(id: "keeper", creationDate: Date(), visualEmbedding: [1, 0, 0])
        keeper.analysisVersion = VisualSignals.analysisVersion
        keeper.qualityScore = 0.8
        keeper.emotionScore = 0.6
        var screenshot = MediaAsset(id: "shot", creationDate: Date(), visualEmbedding: [0, 1, 0])
        screenshot.analysisVersion = VisualSignals.analysisVersion
        screenshot.isUtility = true
        screenshot.qualityScore = 0.1
        var assets = [keeper, screenshot]

        PhotoScoringService.applyPoolSignals(to: &assets)

        XCTAssertGreaterThan(assets[0].analysisScore ?? 0, 0.5)
        XCTAssertLessThan(assets[1].analysisScore ?? 1, 0.3)
        XCTAssertNotNil(assets[0].eventLabel)
    }

    func testAnalysisFieldsRoundTripThroughCodable() throws {
        var asset = MediaAsset(id: "a")
        asset.analysisVersion = VisualSignals.analysisVersion
        asset.isUtility = false
        asset.faceCount = 3
        asset.focusPoint = FocusPoint(x: 0.4, y: 0.3)
        asset.mood = "joyful"
        asset.highlightScore = 0.8

        let decoded = try JSONDecoder().decode(MediaAsset.self, from: JSONEncoder().encode(asset))
        XCTAssertEqual(decoded.analysisVersion, VisualSignals.analysisVersion)
        XCTAssertEqual(decoded.faceCount, 3)
        XCTAssertEqual(decoded.focusPoint, FocusPoint(x: 0.4, y: 0.3))
        XCTAssertEqual(decoded.mood, "joyful")
        XCTAssertEqual(decoded.highlightScore, 0.8)
    }

    func testVisionReadoutRunsOnDeviceModels() async {
        let side = 256
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.8, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 80, y: 80, width: 96, height: 96))

        let readout = await PhotoScoringService.visionReadout(for: context.makeImage()!)

        XCTAssertNotNil(readout.aesthetic)
        XCTAssertEqual(readout.faceCount, 0)
    }
}
