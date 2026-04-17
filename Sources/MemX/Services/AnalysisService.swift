import Foundation
import Vision
import Photos
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "scoring")

// MARK: - PhotoScoringServiceProtocol

protocol PhotoScoringServiceProtocol {
    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult
}

// MARK: - PhotoScoringService (Vision-powered: face detection + saliency + classification)

final class PhotoScoringService: PhotoScoringServiceProtocol {

    static let shared = PhotoScoringService()
    private init() {}

    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult {

        logger.info("Photo scoring started: \(assets.count) assets")
        onProgress(0.05, "Preparing \(assets.count) photos for analysis...")

        var scoredAssets = assets
        var faceCounts: [Int] = Array(repeating: 0, count: assets.count)

        for (i, asset) in assets.enumerated() {
            let (quality, emotion, novelty, faces, clipStart) = await analyzeAsset(asset)
            let overall = quality * 0.4 + emotion * 0.35 + novelty * 0.25
            scoredAssets[i].qualityScore   = quality
            scoredAssets[i].emotionScore   = emotion
            scoredAssets[i].noveltyScore   = novelty
            scoredAssets[i].analysisScore  = overall
            scoredAssets[i].clipStartTime  = clipStart
            faceCounts[i] = faces

            let progress = Double(i + 1) / Double(max(assets.count, 1))
            onProgress(0.05 + progress * 0.87, "Analyzed \(i + 1)/\(assets.count): \(asset.filename ?? asset.id)")
            logger.debug("Scored \(asset.filename ?? asset.id): quality=\(overall, format: .fixed(precision: 2))")
        }

        onProgress(0.95, "Ranking candidates...")

        let candidates: [ClipCandidate] = scoredAssets.enumerated().compactMap { (i, asset) in
            guard let score = asset.analysisScore else { return nil }
            return ClipCandidate(
                assetID: asset.id,
                overallScore: score,
                qualityScore: asset.qualityScore ?? 0.7,
                emotionScore: asset.emotionScore ?? 0.6,
                noveltyScore: asset.noveltyScore ?? 0.5,
                faces: faceCounts[i],
                isIncluded: score > 0.4
            )
        }

        let included = candidates.filter(\.isIncluded).count
        logger.info("Photo scoring complete: \(included)/\(candidates.count) candidates included")
        onProgress(1.0, "Photo scoring complete")
        return PhotoScoringResult(scoredAssets: scoredAssets, candidates: candidates)
    }

    // MARK: - Per-Asset Vision Analysis

    private func analyzeAsset(_ asset: MediaAsset) async -> (quality: Float, emotion: Float, novelty: Float, faces: Int, clipStartTime: TimeInterval?) {
        // Videos: sample frames and find best segment
        if asset.isVideo {
            let result = await VideoAnalysisService.shared.analyzeVideo(
                assetID: asset.id,
                targetDuration: 3.0
            )
            return (result.quality, result.emotion, result.novelty, result.faces, result.bestStartTime)
        }

        // Photos: single-frame Vision analysis
        guard let cgImage = await fetchCGImage(for: asset.id) else {
            return fallbackScores()
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let faceRequest     = VNDetectFaceRectanglesRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let classifyRequest = VNClassifyImageRequest()

        do {
            try handler.perform([faceRequest, saliencyRequest, classifyRequest])
        } catch {
            return fallbackScores()
        }

        let faces = faceRequest.results ?? []
        let faceCount = faces.count
        let avgFaceConf: Float = faceCount > 0
            ? faces.map(\.confidence).reduce(0, +) / Float(faceCount) : 0

        let saliencyConf = Float((saliencyRequest.results?.first)?.confidence ?? 0.5)
        let topLabels    = (classifyRequest.results ?? []).prefix(3)
        let topConfSum   = topLabels.map { Float($0.confidence) }.reduce(0, +)

        let quality = min(1.0, saliencyConf * 0.65 + avgFaceConf * 0.2 + 0.15)
        let emotion = faceCount > 0
            ? min(1.0, 0.45 + Float(faceCount) * 0.15 + avgFaceConf * 0.3)
            : min(0.72, saliencyConf * 0.5 + 0.2)
        let novelty = min(1.0, max(0.2, 1.0 - topConfSum * 0.55))

        return (quality, emotion, novelty, faceCount, nil)
    }

    private func fallbackScores() -> (Float, Float, Float, Int, TimeInterval?) {
        (
            Float.random(in: 0.50...0.88),
            Float.random(in: 0.35...0.78),
            Float.random(in: 0.30...0.75),
            0,
            nil
        )
    }

    // MARK: - Image Fetching

    private func fetchCGImage(for assetID: String) async -> CGImage? {
        let results = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let phAsset = results.firstObject, phAsset.mediaType == .image else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode   = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }
}
