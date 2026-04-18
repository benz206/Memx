import XCTest
@testable import MemXCore

final class MotionPromptModelTests: XCTestCase {

    // MARK: - MotionPrompt init defaults

    func testMotionPromptDefaultPromptEmpty() {
        let mp = MotionPrompt(assetID: "asset-1")
        XCTAssertEqual(mp.prompt, "")
    }

    func testMotionPromptNotEditedByDefault() {
        let mp = MotionPrompt(assetID: "asset-1")
        XCTAssertFalse(mp.isEdited)
    }

    func testMotionPromptDefaultIntensity() {
        let mp = MotionPrompt(assetID: "asset-1")
        XCTAssertEqual(mp.motionIntensity, 0.5, accuracy: 0.001)
    }

    func testMotionPromptDefaultStatusPending() {
        let mp = MotionPrompt(assetID: "asset-1")
        XCTAssertEqual(mp.status, .pending)
    }

    func testMotionPromptStoresAssetID() {
        let mp = MotionPrompt(assetID: "mock-asset-42")
        XCTAssertEqual(mp.assetID, "mock-asset-42")
    }

    // MARK: - MotionPromptStatus icons

    func testPendingStatusIcon() {
        XCTAssertEqual(MotionPromptStatus.pending.icon, "hourglass")
    }

    func testGeneratingStatusIcon() {
        XCTAssertEqual(MotionPromptStatus.generating.icon, "sparkles")
    }

    func testReadyStatusIcon() {
        XCTAssertEqual(MotionPromptStatus.ready.icon, "checkmark.circle.fill")
    }

    func testEditedStatusIcon() {
        XCTAssertEqual(MotionPromptStatus.edited.icon, "pencil.circle.fill")
    }

    // MARK: - MotionPromptStatus colors

    func testAllStatusesHaveColors() {
        for status in [MotionPromptStatus.pending, .generating, .ready, .edited] {
            XCTAssertFalse(status.color.isEmpty, "\(status) color is empty")
        }
    }

    func testReadyStatusIsGreen() {
        XCTAssertEqual(MotionPromptStatus.ready.color, "green")
    }

    func testEditedStatusIsBlue() {
        XCTAssertEqual(MotionPromptStatus.edited.color, "blue")
    }

    // MARK: - Codable

    func testMotionPromptCodableRoundTrip() throws {
        let mp = MotionPrompt(
            assetID: "asset-7",
            prompt: "Slow push-in toward the horizon.",
            isEdited: true,
            motionIntensity: 0.8,
            status: .ready
        )
        let data = try JSONEncoder().encode(mp)
        let decoded = try JSONDecoder().decode(MotionPrompt.self, from: data)
        XCTAssertEqual(decoded.id, mp.id)
        XCTAssertEqual(decoded.assetID, "asset-7")
        XCTAssertEqual(decoded.prompt, "Slow push-in toward the horizon.")
        XCTAssertTrue(decoded.isEdited)
        XCTAssertEqual(decoded.motionIntensity, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.status, .ready)
    }
}
