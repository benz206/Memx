import XCTest
@testable import MemXCore

final class MockDataProviderTests: XCTestCase {

    // MARK: - mockAssets

    func testMockAssetsCount() {
        XCTAssertEqual(MockDataProvider.mockAssets().count, 20)
    }

    func testMockAssetsHaveUniqueIDs() {
        let assets = MockDataProvider.mockAssets()
        let ids = Set(assets.map(\.id))
        XCTAssertEqual(ids.count, assets.count)
    }

    func testMockAssetsHaveAnalysisScores() {
        let assets = MockDataProvider.mockAssets()
        for asset in assets {
            XCTAssertNotNil(asset.analysisScore, "Asset \(asset.id) missing analysisScore")
            XCTAssertNotNil(asset.qualityScore)
            XCTAssertNotNil(asset.emotionScore)
            XCTAssertNotNil(asset.noveltyScore)
        }
    }

    func testMockAssetsScoresInRange() {
        let assets = MockDataProvider.mockAssets()
        for asset in assets {
            if let score = asset.analysisScore {
                XCTAssertGreaterThanOrEqual(score, 0)
                XCTAssertLessThanOrEqual(score, 1.0)
            }
        }
    }

    func testMockAssetsHaveVideos() {
        let assets = MockDataProvider.mockAssets()
        let videos = assets.filter { $0.isVideo }
        XCTAssertFalse(videos.isEmpty, "Expected at least one video asset")
    }

    func testMockAssetsVideosDuration() {
        let assets = MockDataProvider.mockAssets()
        let videos = assets.filter { $0.isVideo }
        for video in videos {
            XCTAssertGreaterThan(video.duration, 0)
        }
    }

    func testMockAssetsHaveFavorites() {
        let assets = MockDataProvider.mockAssets()
        let favorites = assets.filter { $0.isFavorite }
        XCTAssertFalse(favorites.isEmpty, "Expected some favorite assets")
    }

    // MARK: - mockBeatmap

    func testMockBeatmapDefaultDuration() {
        let beatmap = MockDataProvider.mockBeatmap()
        XCTAssertEqual(beatmap.durationSeconds, 214, accuracy: 0.001)
    }

    func testMockBeatmapCustomDuration() {
        let beatmap = MockDataProvider.mockBeatmap(duration: 180)
        XCTAssertEqual(beatmap.durationSeconds, 180, accuracy: 0.001)
    }

    func testMockBeatmapBeatsNonEmpty() {
        let beatmap = MockDataProvider.mockBeatmap()
        XCTAssertFalse(beatmap.beats.isEmpty)
    }

    func testMockBeatmapBeatsDoNotExceedDuration() {
        let beatmap = MockDataProvider.mockBeatmap()
        for beat in beatmap.beats {
            XCTAssertLessThan(beat, beatmap.durationSeconds)
        }
    }

    func testMockBeatmapBeatsAreAscending() {
        let beatmap = MockDataProvider.mockBeatmap()
        for i in 1..<beatmap.beats.count {
            XCTAssertGreaterThan(beatmap.beats[i], beatmap.beats[i - 1])
        }
    }

    func testMockBeatmapSectionsNonEmpty() {
        let beatmap = MockDataProvider.mockBeatmap()
        XCTAssertFalse(beatmap.sections.isEmpty)
    }

    func testMockBeatmapSectionsCoverFullDuration() {
        let beatmap = MockDataProvider.mockBeatmap()
        let firstStart = beatmap.sections.map(\.start).min() ?? 0
        let lastEnd = beatmap.sections.map(\.end).max() ?? 0
        XCTAssertEqual(firstStart, 0, accuracy: 0.001)
        XCTAssertEqual(lastEnd, beatmap.durationSeconds, accuracy: 0.001)
    }

    func testMockBeatmapHasBPM() {
        let beatmap = MockDataProvider.mockBeatmap()
        XCTAssertGreaterThan(beatmap.bpm, 0)
        XCTAssertLessThan(beatmap.bpm, 300)
    }

    func testMockBeatmapHasDrops() {
        let beatmap = MockDataProvider.mockBeatmap()
        XCTAssertFalse(beatmap.drops.isEmpty)
    }

    func testMockBeatmapDropsHaveHighIntensity() {
        let beatmap = MockDataProvider.mockBeatmap()
        for drop in beatmap.drops {
            XCTAssertGreaterThan(drop.intensity, 0.5)
        }
    }

    func testMockBeatmapEnergyCurveNonEmpty() {
        let beatmap = MockDataProvider.mockBeatmap()
        XCTAssertFalse(beatmap.energyCurve.isEmpty)
    }

    func testMockBeatmapEnergyCurveValuesInRange() {
        let beatmap = MockDataProvider.mockBeatmap()
        for point in beatmap.energyCurve {
            XCTAssertGreaterThanOrEqual(point.energy, 0)
            XCTAssertLessThanOrEqual(point.energy, 1.0)
        }
    }

    // MARK: - demoProject

    func testDemoProjectStatusIsReady() {
        XCTAssertEqual(MockDataProvider.demoProject().status, .ready)
    }

    func testDemoProjectHasSongTrack() {
        XCTAssertNotNil(MockDataProvider.demoProject().songTrack)
    }

    func testDemoProjectHasMontagePlan() {
        XCTAssertNotNil(MockDataProvider.demoProject().montagePlan)
    }

    func testDemoProjectHasAssets() {
        XCTAssertFalse(MockDataProvider.demoProject().assetIDs.isEmpty)
    }

    func testDemoProjectMontagePlanHasSequence() {
        let plan = MockDataProvider.demoProject().montagePlan!
        XCTAssertFalse(plan.sequence.isEmpty)
    }

    // MARK: - sampleProjects

    func testSampleProjectsCount() {
        XCTAssertEqual(MockDataProvider.sampleProjects().count, 3)
    }

    func testSampleProjectsHaveUniqueIDs() {
        let projects = MockDataProvider.sampleProjects()
        let ids = Set(projects.map(\.id))
        XCTAssertEqual(ids.count, projects.count)
    }

    func testSampleProjectsHaveTitles() {
        let projects = MockDataProvider.sampleProjects()
        for project in projects {
            XCTAssertFalse(project.title.isEmpty)
        }
    }

    // MARK: - mockMotionPrompts

    func testMockMotionPromptsCountMatchesAssets() {
        let assets = MockDataProvider.mockAssets()
        let prompts = MockDataProvider.mockMotionPrompts(for: assets)
        XCTAssertEqual(prompts.count, assets.count)
    }

    func testMockMotionPromptsHavePromptText() {
        let assets = Array(MockDataProvider.mockAssets().prefix(5))
        let prompts = MockDataProvider.mockMotionPrompts(for: assets)
        for prompt in prompts {
            XCTAssertFalse(prompt.prompt.isEmpty, "Expected non-empty prompt text")
        }
    }

    func testMockMotionPromptsAssetIDsMatch() {
        let assets = MockDataProvider.mockAssets()
        let prompts = MockDataProvider.mockMotionPrompts(for: assets)
        let promptAssetIDs = Set(prompts.map(\.assetID))
        let assetIDs = Set(assets.map(\.id))
        XCTAssertEqual(promptAssetIDs, assetIDs)
    }

    func testMockMotionPromptsStatusIsReady() {
        let assets = Array(MockDataProvider.mockAssets().prefix(3))
        let prompts = MockDataProvider.mockMotionPrompts(for: assets)
        for prompt in prompts {
            XCTAssertEqual(prompt.status, .ready)
        }
    }

    // MARK: - completedProcessingStatus

    func testCompletedProcessingStatusPhase() {
        let project = MockDataProvider.demoProject()
        let status = MockDataProvider.completedProcessingStatus(for: project)
        XCTAssertEqual(status.phase, .complete)
    }

    func testCompletedProcessingStatusProgress() {
        let project = MockDataProvider.demoProject()
        let status = MockDataProvider.completedProcessingStatus(for: project)
        XCTAssertEqual(status.progress, 1.0, accuracy: 0.001)
    }

    func testCompletedProcessingStatusHasCompletedAt() {
        let project = MockDataProvider.demoProject()
        let status = MockDataProvider.completedProcessingStatus(for: project)
        XCTAssertNotNil(status.completedAt)
    }

    func testCompletedProcessingStatusIsComplete() {
        let project = MockDataProvider.demoProject()
        let status = MockDataProvider.completedProcessingStatus(for: project)
        XCTAssertTrue(status.isComplete)
        XCTAssertFalse(status.isFailed)
    }

    // MARK: - mockSongTrack

    func testMockSongTrackHasTitle() {
        XCTAssertFalse(MockDataProvider.mockSongTrack().title.isEmpty)
    }

    func testMockSongTrackHasDuration() {
        XCTAssertGreaterThan(MockDataProvider.mockSongTrack().durationSeconds, 0)
    }

    func testMockSongTrackHasArtist() {
        XCTAssertNotNil(MockDataProvider.mockSongTrack().artist)
    }

    // MARK: - mockAlbums

    func testMockAlbumsNonEmpty() {
        XCTAssertFalse(MockDataProvider.mockAlbums().isEmpty)
    }

    func testMockAlbumsHavePositiveCounts() {
        for album in MockDataProvider.mockAlbums() {
            XCTAssertGreaterThan(album.count, 0, "\(album.title) has non-positive count")
        }
    }

    func testMockAlbumsHaveTitles() {
        for album in MockDataProvider.mockAlbums() {
            XCTAssertFalse(album.title.isEmpty)
        }
    }
}
