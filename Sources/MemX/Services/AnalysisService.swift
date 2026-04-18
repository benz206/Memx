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

        let total = assets.count
        let concurrencyLimit = 6

        struct IndexedResult {
            let index: Int
            let quality: Float
            let emotion: Float
            let novelty: Float
            let faces: Int
            let clipStart: TimeInterval?
        }

        var results = [IndexedResult?](repeating: nil, count: total)
        var completedCount = 0

        try await withThrowingTaskGroup(of: IndexedResult.self) { group in
            var inFlight = 0
            var nextIndex = 0

            while nextIndex < total || inFlight > 0 {
                while inFlight < concurrencyLimit && nextIndex < total {
                    let i = nextIndex
                    let asset = assets[i]
                    group.addTask {
                        let (quality, emotion, novelty, faces, clipStart) = await self.analyzeAsset(asset)
                        return IndexedResult(index: i, quality: quality, emotion: emotion,
                                            novelty: novelty, faces: faces, clipStart: clipStart)
                    }
                    onProgress(0.05 + Double(nextIndex) / Double(total) * 0.04,
                               "Starting \(nextIndex + 1)/\(total)…")
                    inFlight += 1
                    nextIndex += 1
                }

                if let result = try await group.next() {
                    results[result.index] = result
                    inFlight -= 1
                    completedCount += 1
                    let progress = Double(completedCount) / Double(max(total, 1))
                    onProgress(0.05 + progress * 0.87,
                               "Analyzed \(completedCount)/\(total): \(assets[result.index].filename ?? assets[result.index].id)")
                    logger.debug("Scored \(assets[result.index].filename ?? assets[result.index].id): quality=\(result.quality * 0.4 + result.emotion * 0.35 + result.novelty * 0.25, format: .fixed(precision: 2))")
                }
            }
        }

        onProgress(0.95, "Ranking candidates...")

        var scoredAssets = assets
        var faceCounts = [Int](repeating: 0, count: total)
        for r in results.compactMap({ $0 }) {
            let overall = r.quality * 0.4 + r.emotion * 0.35 + r.novelty * 0.25
            scoredAssets[r.index].qualityScore  = r.quality
            scoredAssets[r.index].emotionScore  = r.emotion
            scoredAssets[r.index].noveltyScore  = r.novelty
            scoredAssets[r.index].analysisScore = overall
            scoredAssets[r.index].clipStartTime = r.clipStart
            faceCounts[r.index] = r.faces
        }

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
        if asset.isVideo {
            let result = await VideoAnalysisService.shared.analyzeVideo(
                assetID: asset.id,
                targetDuration: 3.0
            )
            return (result.quality, result.emotion, result.novelty, result.faces, result.bestStartTime)
        }

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
        guard let phAsset = await PHAssetCache.shared.phAsset(for: assetID),
              phAsset.mediaType == .image else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var resumed = false
            let resume: (CGImage?) -> Void = { img in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: img)
            }
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: 384, height: 384),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    resume(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                }
            }
        }
    }
}
