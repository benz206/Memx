import Foundation

// MARK: - PhotoScoringServiceProtocol

protocol PhotoScoringServiceProtocol {
    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult
}

// MARK: - PhotoScoringService (mocked — ready for on-device Vision / Core ML)

final class PhotoScoringService: PhotoScoringServiceProtocol {

    static let shared = PhotoScoringService()
    private init() {}

    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult {

        onProgress(0.1, "Loading \(assets.count) photos...")
        try await Task.sleep(for: .milliseconds(400))

        // TODO: Replace with Vision / Core ML pipeline:
        //   - VNImageRequestHandler for composition analysis
        //   - VNDetectFaceRectanglesRequest for face scoring
        //   - VNGenerateAttentionBasedSaliencyImageRequest for focus
        //   - Custom Core ML model for emotion score

        onProgress(0.5, "Analyzing composition and emotion...")
        var scoredAssets = assets
        for i in scoredAssets.indices {
            let quality  = Float.random(in: 0.5...1.0)
            let emotion  = Float.random(in: 0.3...1.0)
            let novelty  = Float.random(in: 0.2...1.0)
            let overall  = quality * 0.4 + emotion * 0.35 + novelty * 0.25
            scoredAssets[i].qualityScore = quality
            scoredAssets[i].emotionScore = emotion
            scoredAssets[i].noveltyScore = novelty
            scoredAssets[i].analysisScore = overall
        }
        try await Task.sleep(for: .milliseconds(700))

        onProgress(0.9, "Ranking candidates...")
        let candidates = scoredAssets.compactMap { asset -> ClipCandidate? in
            guard let score = asset.analysisScore else { return nil }
            return ClipCandidate(
                assetID: asset.id,
                overallScore: score,
                qualityScore: asset.qualityScore ?? 0.7,
                emotionScore: asset.emotionScore ?? 0.6,
                noveltyScore: asset.noveltyScore ?? 0.5,
                faces: Int.random(in: 0...3),
                isIncluded: score > 0.4
            )
        }
        try await Task.sleep(for: .milliseconds(300))

        onProgress(1.0, "Photo scoring complete")
        return PhotoScoringResult(scoredAssets: scoredAssets, candidates: candidates)
    }
}
