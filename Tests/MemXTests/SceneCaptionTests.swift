import XCTest
@testable import MemXCore

final class SceneCaptionTests: XCTestCase {

    // MARK: - MediaAsset Codable round-trip with scene fields

    func testMediaAssetCodableRoundTripWithSceneFields() throws {
        var asset = MediaAsset(
            id: "asset-scene-1",
            mediaType: .photo,
            pixelWidth: 1920,
            pixelHeight: 1280
        )
        asset.sceneLabels = ["beach", "sunset", "people"]
        asset.sceneCaption = "Two friends walking along a sandy beach at sunset"
        asset.qualityScore = 0.82
        asset.emotionScore = 0.74
        asset.noveltyScore = 0.41
        asset.analysisScore = 0.7

        let encoder = JSONEncoder()
        let data = try encoder.encode(asset)
        let decoded = try JSONDecoder().decode(MediaAsset.self, from: data)

        XCTAssertEqual(decoded.sceneLabels, ["beach", "sunset", "people"])
        XCTAssertEqual(decoded.sceneCaption, "Two friends walking along a sandy beach at sunset")
        XCTAssertEqual(decoded.qualityScore, 0.82)
    }

    func testMediaAssetCodableNilSceneFieldsDefault() throws {
        let asset = MediaAsset(id: "asset-no-scene")
        let data = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(MediaAsset.self, from: data)
        XCTAssertNil(decoded.sceneLabels)
        XCTAssertNil(decoded.sceneCaption)
    }

    // MARK: - Backward compatibility: legacy JSON without scene fields decodes

    func testMediaAssetLegacyJSONDecodesWithoutSceneFields() throws {
        // Simulates a persisted project from before scene analysis was added.
        // The encoder must still accept this payload and produce nil for the
        // new optional fields.
        let legacyJSON = """
        {
          "id": "legacy-asset-1",
          "mediaType": "Photo",
          "pixelWidth": 1920,
          "pixelHeight": 1080,
          "isFavorite": false,
          "duration": 0,
          "isSelected": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MediaAsset.self, from: legacyJSON)
        XCTAssertEqual(decoded.id, "legacy-asset-1")
        XCTAssertEqual(decoded.mediaType, .photo)
        XCTAssertNil(decoded.sceneLabels)
        XCTAssertNil(decoded.sceneCaption)
        XCTAssertNil(decoded.qualityScore)
    }

    // MARK: - SceneCaptionService protocol conformance via mock

    func testMockSceneCaptionServiceReturnsExpectedString() async {
        let mock = MockSceneCaptionService(canned: "A warm golden hour over a quiet beach")
        // A 1x1 stub CGImage is enough because the mock ignores the image.
        let stub = Self.stubCGImage()
        let result = await mock.caption(for: stub, sceneLabels: ["beach", "sunset"])
        XCTAssertEqual(result, "A warm golden hour over a quiet beach")
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations.first?.labels, ["beach", "sunset"])
    }

    func testMockSceneCaptionServiceReturnsNilWhenConfigured() async {
        let mock = MockSceneCaptionService(canned: nil)
        let stub = Self.stubCGImage()
        let result = await mock.caption(for: stub, sceneLabels: ["indoor"])
        XCTAssertNil(result)
    }

    // MARK: - LocalVLMService protocol conformance

    func testLocalVLMServiceSharedIsAccessible() {
        let service = LocalVLMService.shared
        XCTAssertNotNil(service)
    }

    func testMockLocalVLMServiceReturnsNilWhenConfigured() async {
        let mock = MockLocalVLMService(canned: nil)
        let stub = Self.stubCGImage()
        let result = await mock.describe(
            image: stub,
            instructions: "System prompt",
            prompt: "Caption this photo.",
            maxTokens: 60
        )
        XCTAssertNil(result)
    }

    func testMockLocalVLMServiceReturnsCannedString() async {
        let mock = MockLocalVLMService(canned: "Golden light spills across an empty desert road")
        let stub = Self.stubCGImage()
        let result = await mock.describe(
            image: stub,
            instructions: "System prompt",
            prompt: "Caption this photo.",
            maxTokens: 60
        )
        XCTAssertEqual(result, "Golden light spills across an empty desert road")
    }

    // MARK: - Helpers

    private static func stubCGImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}

// MARK: - Mock LocalVLMService

private final class MockLocalVLMService: LocalVLMServiceProtocol {
    let canned: String?

    init(canned: String?) {
        self.canned = canned
    }

    func describe(image: CGImage, instructions: String, prompt: String, maxTokens: Int) async -> String? {
        return canned
    }
}

// MARK: - Mock SceneCaptionService

/// Test double that records each call and returns a fixed string.
/// Lives in the test module so it can conform to the internal protocol.
private final class MockSceneCaptionService: SceneCaptionServiceProtocol {
    struct Invocation {
        let labels: [String]
    }

    let canned: String?
    private(set) var invocations: [Invocation] = []

    init(canned: String?) {
        self.canned = canned
    }

    func caption(for cgImage: CGImage, sceneLabels: [String]) async -> String? {
        invocations.append(Invocation(labels: sceneLabels))
        return canned
    }
}
