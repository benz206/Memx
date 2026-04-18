import XCTest
@testable import MemXCore

final class ScoringDensityTests: XCTestCase {

    // MARK: - videoFrameSamples

    func testVideoFrameSamplesVerySparse() {
        XCTAssertEqual(ScoringDensity.verySparse.videoFrameSamples, 8)
    }

    func testVideoFrameSamplesSparse() {
        XCTAssertEqual(ScoringDensity.sparse.videoFrameSamples, 14)
    }

    func testVideoFrameSamplesBalanced() {
        XCTAssertEqual(ScoringDensity.balanced.videoFrameSamples, 20)
    }

    func testVideoFrameSamplesDense() {
        XCTAssertEqual(ScoringDensity.dense.videoFrameSamples, 30)
    }

    func testVideoFrameSamplesVeryDense() {
        XCTAssertEqual(ScoringDensity.veryDense.videoFrameSamples, 48)
    }

    func testVideoFrameSamplesMonotonicallyIncreasing() {
        let ordered: [ScoringDensity] = [.verySparse, .sparse, .balanced, .dense, .veryDense]
        let samples = ordered.map(\.videoFrameSamples)
        XCTAssertEqual(samples, samples.sorted(), "Sample counts should increase with density")
    }

    // MARK: - Metadata

    func testAllCasesHaveDescription() {
        for d in ScoringDensity.allCases {
            XCTAssertFalse(d.description.isEmpty, "\(d) description is empty")
        }
    }

    func testAllCasesHaveIcon() {
        for d in ScoringDensity.allCases {
            XCTAssertFalse(d.icon.isEmpty, "\(d) icon is empty")
        }
    }

    // MARK: - MontageSettings default

    func testMontageSettingsDefaultDensityIsBalanced() {
        let settings = MontageSettings()
        XCTAssertEqual(settings.scoringDensity, .balanced)
    }

    func testProjectDefaultSettingsHaveBalancedDensity() {
        let project = Project(title: "Test")
        XCTAssertEqual(project.settings.scoringDensity, .balanced)
    }

    // MARK: - Backward-compatible decoding

    func testDecodingLegacyJSONWithoutScoringDensityDefaultsToBalanced() throws {
        // Legacy JSON — pre-scoringDensity era. Must still decode.
        let legacyJSON = """
        {
            "vibe": "Cinematic",
            "focus": "Everything",
            "aspectRatio": "16:9",
            "renderQuality": "2.5D Parallax",
            "songVolume": 0.5
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MontageSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.scoringDensity, .balanced)
        XCTAssertEqual(decoded.vibe, .cinematic)
        XCTAssertEqual(decoded.focus, .everything)
        XCTAssertEqual(decoded.aspectRatio, .widescreen)
        XCTAssertEqual(decoded.renderQuality, .parallax2D)
    }

    // MARK: - Codable round-trip

    func testMontageSettingsCodableRoundTripPreservesDensity() throws {
        for density in ScoringDensity.allCases {
            let settings = MontageSettings(
                vibe: .hype,
                focus: .friends,
                aspectRatio: .portrait,
                renderQuality: .hybrid,
                songVolume: 0.42,
                scoringDensity: density
            )
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(MontageSettings.self, from: data)
            XCTAssertEqual(decoded.scoringDensity, density, "Round trip failed for \(density)")
            XCTAssertEqual(decoded.vibe, settings.vibe)
            XCTAssertEqual(decoded.focus, settings.focus)
            XCTAssertEqual(decoded.aspectRatio, settings.aspectRatio)
            XCTAssertEqual(decoded.renderQuality, settings.renderQuality)
            XCTAssertEqual(decoded.songVolume, settings.songVolume, accuracy: 0.0001)
        }
    }

    func testProjectCodableRoundTripPreservesDensity() throws {
        var project = Project(
            title: "Density Test",
            settings: MontageSettings(scoringDensity: .veryDense)
        )
        project.status = .ready
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.settings.scoringDensity, .veryDense)
    }

    // MARK: - Raw values (stable for storage)

    func testRawValuesAreStable() {
        XCTAssertEqual(ScoringDensity.verySparse.rawValue, "Very Sparse")
        XCTAssertEqual(ScoringDensity.sparse.rawValue,     "Sparse")
        XCTAssertEqual(ScoringDensity.balanced.rawValue,   "Balanced")
        XCTAssertEqual(ScoringDensity.dense.rawValue,      "Dense")
        XCTAssertEqual(ScoringDensity.veryDense.rawValue,  "Very Dense")
    }
}
