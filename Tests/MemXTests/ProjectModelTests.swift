import XCTest
@testable import MemXCore

final class ProjectModelTests: XCTestCase {

    // MARK: - Project Init

    func testProjectDefaultStatus() {
        let project = Project(title: "Test")
        XCTAssertEqual(project.status, .draft)
    }

    func testProjectDefaultAssetIDsEmpty() {
        let project = Project(title: "Test")
        XCTAssertTrue(project.assetIDs.isEmpty)
    }

    func testProjectDefaultSettingsAreDefault() {
        let project = Project(title: "Test")
        XCTAssertEqual(project.settings.vibe, .cinematic)
        XCTAssertEqual(project.settings.focus, .everything)
        XCTAssertEqual(project.settings.aspectRatio, .widescreen)
        XCTAssertEqual(project.settings.renderQuality, .parallax2D)
    }

    func testProjectNoMontagePlanOnInit() {
        let project = Project(title: "Test")
        XCTAssertNil(project.montagePlan)
        XCTAssertNil(project.songTrack)
    }

    func testProjectUpdatedAtMatchesCreatedAt() {
        let project = Project(title: "Test")
        XCTAssertEqual(project.createdAt, project.updatedAt)
    }

    func testProjectIDIsUnique() {
        let a = Project(title: "A")
        let b = Project(title: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - ProjectStatus

    func testProjectStatusAllCasesHaveIcons() {
        for status in ProjectStatus.allCases {
            XCTAssertFalse(status.icon.isEmpty, "\(status) icon is empty")
        }
    }

    func testProjectStatusRawValues() {
        XCTAssertEqual(ProjectStatus.draft.rawValue, "Draft")
        XCTAssertEqual(ProjectStatus.importing.rawValue, "Importing")
        XCTAssertEqual(ProjectStatus.analyzing.rawValue, "Analyzing")
        XCTAssertEqual(ProjectStatus.ready.rawValue, "Ready")
        XCTAssertEqual(ProjectStatus.exported.rawValue, "Exported")
    }

    // MARK: - AspectRatio

    func testAspectRatioCGRatioWidescreen() {
        XCTAssertEqual(AspectRatio.widescreen.cgRatio, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testAspectRatioCGRatioPortrait() {
        XCTAssertEqual(AspectRatio.portrait.cgRatio, 9.0 / 16.0, accuracy: 0.0001)
    }

    func testAspectRatioCGRatioSquare() {
        XCTAssertEqual(AspectRatio.square.cgRatio, 1.0, accuracy: 0.0001)
    }

    func testAspectRatioRawValues() {
        XCTAssertEqual(AspectRatio.portrait.rawValue, "9:16")
        XCTAssertEqual(AspectRatio.widescreen.rawValue, "16:9")
        XCTAssertEqual(AspectRatio.square.rawValue, "1:1")
    }

    // MARK: - MontageVibe

    func testMontageVibeAllCasesHaveDescriptions() {
        for vibe in MontageVibe.allCases {
            XCTAssertFalse(vibe.description.isEmpty, "\(vibe) description is empty")
        }
    }

    func testMontageVibeAllCasesHaveIcons() {
        for vibe in MontageVibe.allCases {
            XCTAssertFalse(vibe.icon.isEmpty, "\(vibe) icon is empty")
        }
    }

    // MARK: - MontageFocus

    func testMontageFocusAllCasesHaveIcons() {
        for focus in MontageFocus.allCases {
            XCTAssertFalse(focus.icon.isEmpty, "\(focus) icon is empty")
        }
    }

    // MARK: - RenderQuality

    func testRenderQualityAllCasesHaveDescriptions() {
        for quality in RenderQuality.allCases {
            XCTAssertFalse(quality.description.isEmpty, "\(quality) description is empty")
        }
    }

    func testRenderQualityAllCasesHaveIcons() {
        for quality in RenderQuality.allCases {
            XCTAssertFalse(quality.icon.isEmpty, "\(quality) icon is empty")
        }
    }

    // MARK: - Codable round-trip

    func testProjectCodableRoundTrip() throws {
        var project = Project(title: "Codable Test", settings: MontageSettings(vibe: .hype, focus: .friends))
        project.status = .ready
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.id, project.id)
        XCTAssertEqual(decoded.title, project.title)
        XCTAssertEqual(decoded.status, project.status)
        XCTAssertEqual(decoded.settings.vibe, project.settings.vibe)
        XCTAssertEqual(decoded.settings.focus, project.settings.focus)
    }

    func testMontageSettingsCodableRoundTrip() throws {
        let settings = MontageSettings(vibe: .travel, focus: .scenery, aspectRatio: .portrait, renderQuality: .generative)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MontageSettings.self, from: data)
        XCTAssertEqual(decoded.vibe, settings.vibe)
        XCTAssertEqual(decoded.focus, settings.focus)
        XCTAssertEqual(decoded.aspectRatio, settings.aspectRatio)
        XCTAssertEqual(decoded.renderQuality, settings.renderQuality)
    }
}
