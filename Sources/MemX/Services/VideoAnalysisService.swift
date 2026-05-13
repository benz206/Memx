import Foundation

// MARK: - VideoAnalysisResult

struct VideoAnalysisResult {
    var quality: Float
    var emotion: Float
    var novelty: Float
    var faces: Int
    var bestStartTime: TimeInterval
    var shotType: ShotType?
    var motionVector: MotionVector?
    var colorTemperature: Double?
    var faceAreaFraction: Double?
    var sceneLabels: [String]?
    var sceneCaption: String?
}

// MARK: - VideoAnalysisService

/// Compatibility facade.
///
/// Video scoring moved into `PhotoScoringService`, which sends one
/// representative frame and metadata to OpenRouter. This type remains so older
/// tests or call sites can compile without invoking a local Vision pipeline.
final class VideoAnalysisService {
    static let shared = VideoAnalysisService()
    private init() {}

    func analyzeVideo(
        assetID: String,
        targetDuration: TimeInterval,
        density: ScoringDensity = .balanced
    ) async -> VideoAnalysisResult {
        VideoAnalysisResult(
            quality: 0.62,
            emotion: 0.55,
            novelty: 0.60,
            faces: 0,
            bestStartTime: 0,
            shotType: .wide,
            motionVector: nil,
            colorTemperature: 0.5,
            faceAreaFraction: nil,
            sceneLabels: ["video"],
            sceneCaption: nil
        )
    }
}
