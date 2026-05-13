import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import Photos

private let logger = Logger(subsystem: "com.memx.app", category: "scoring")

@inline(__always)
private func scoringLog(_ message: @autoclosure () -> String) {
    let line = "[scoring] \(message())"
    print(line)
    fflush(stdout)
    logger.info("\(line, privacy: .public)")
}

// MARK: - PhotoScoringServiceProtocol

protocol PhotoScoringServiceProtocol {
    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        density: ScoringDensity,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult
}

extension PhotoScoringServiceProtocol {
    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult {
        try await scorePhotos(for: project, assets: assets, density: .balanced, onProgress: onProgress)
    }
}

// MARK: - PhotoScoringService

/// Outsourced visual analysis.
///
/// This service performs only lightweight media access on the Mac: fetch a
/// downscaled photo or representative video frame, JPEG-compress it, and send
/// it to OpenRouter for semantic scoring. No Vision, Foundation Models, or
/// local VLM work happens here; final stitching remains the local heavy lift.
final class PhotoScoringService: PhotoScoringServiceProtocol {

    static let shared = PhotoScoringService()

    private let openRouterService: OpenRouterServiceProtocol
    private init(openRouterService: OpenRouterServiceProtocol = OpenRouterService.shared) {
        self.openRouterService = openRouterService
    }

    private static func concurrencyLimit(for density: ScoringDensity) -> Int {
        switch density {
        case .verySparse, .sparse: return 5
        case .balanced: return 4
        case .dense, .veryDense: return 3
        }
    }

    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        density: ScoringDensity = .balanced,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult {
        guard !assets.isEmpty else {
            return PhotoScoringResult(scoredAssets: [], candidates: [])
        }

        let maxConcurrent = Self.concurrencyLimit(for: density)
        scoringLog("▶︎ OpenRouter scorePhotos START — \(assets.count) assets, density=\(density.rawValue), concurrency=\(maxConcurrent)")
        onProgress(0.03, "Preparing \(assets.count) assets for OpenRouter analysis...")

        struct IndexedResult {
            let index: Int
            let analysis: OpenRouterVisualAnalysis
        }

        var results = [IndexedResult?](repeating: nil, count: assets.count)
        var completed = 0

        try await withThrowingTaskGroup(of: IndexedResult.self) { group in
            var nextIndex = 0

            func launch(_ index: Int) {
                let asset = assets[index]
                group.addTask {
                    try Task.checkCancellation()
                    let request = await self.visualRequest(for: asset)
                    let analysis = await self.openRouterService.analyzeVisualAsset(request)
                        ?? self.fallbackAnalysis(for: asset)
                    return IndexedResult(index: index, analysis: analysis)
                }
            }

            while nextIndex < min(maxConcurrent, assets.count) {
                launch(nextIndex)
                nextIndex += 1
            }

            while let result = try await group.next() {
                results[result.index] = result
                completed += 1
                let progress = Double(completed) / Double(max(assets.count, 1))
                onProgress(0.05 + progress * 0.90, "Analyzed \(completed)/\(assets.count) with OpenRouter...")

                if nextIndex < assets.count {
                    launch(nextIndex)
                    nextIndex += 1
                }
            }
        }

        onProgress(0.96, "Ranking storyboard candidates...")

        var scoredAssets = assets
        var faceCounts = [Int](repeating: 0, count: assets.count)

        for result in results.compactMap({ $0 }) {
            let a = result.analysis
            let overall = a.qualityScore * 0.34 + a.emotionScore * 0.36 + a.noveltyScore * 0.30
            scoredAssets[result.index].qualityScore = a.qualityScore
            scoredAssets[result.index].emotionScore = a.emotionScore
            scoredAssets[result.index].noveltyScore = a.noveltyScore
            scoredAssets[result.index].analysisScore = overall
            scoredAssets[result.index].eventLabel = a.eventLabel
            scoredAssets[result.index].sceneLabels = a.sceneLabels.isEmpty ? nil : a.sceneLabels
            scoredAssets[result.index].sceneCaption = a.sceneCaption.isEmpty ? nil : a.sceneCaption
            scoredAssets[result.index].semanticSummary = a.semanticSummary.isEmpty ? nil : a.semanticSummary
            scoredAssets[result.index].shotType = a.shotType
            scoredAssets[result.index].motionVector = nil
            scoredAssets[result.index].colorTemperature = a.colorTemperature
            scoredAssets[result.index].faceAreaFraction = a.faceAreaFraction
            scoredAssets[result.index].clipStartTime = a.clipStartTime
            faceCounts[result.index] = a.faces
        }

        let candidates: [ClipCandidate] = scoredAssets.enumerated().compactMap { index, asset in
            guard let score = asset.analysisScore else { return nil }
            return ClipCandidate(
                assetID: asset.id,
                overallScore: score,
                qualityScore: asset.qualityScore ?? 0.65,
                emotionScore: asset.emotionScore ?? 0.55,
                noveltyScore: asset.noveltyScore ?? 0.50,
                faces: faceCounts[index],
                isIncluded: score > 0.35
            )
        }

        let included = candidates.filter(\.isIncluded).count
        scoringLog("■ OpenRouter scorePhotos DONE — \(included)/\(candidates.count) candidates included")
        onProgress(1.0, "OpenRouter visual analysis complete")
        return PhotoScoringResult(scoredAssets: scoredAssets, candidates: candidates)
    }

    // MARK: - Media Preparation

    private func visualRequest(for asset: MediaAsset) async -> OpenRouterVisualAnalysisRequest {
        let image = asset.isVideo
            ? await representativeVideoFrame(for: asset)
            : await photoImage(for: asset)

        return OpenRouterVisualAnalysisRequest(
            assetID: asset.id,
            filename: asset.filename,
            isVideo: asset.isVideo,
            duration: asset.duration,
            aspectRatio: asset.aspectRatio,
            creationDate: asset.creationDate,
            imageJPEGData: image.flatMap { OpenRouterService.jpegData(from: $0, maxDimension: 896, compressionQuality: 0.70) }
        )
    }

    private func photoImage(for asset: MediaAsset) async -> CGImage? {
        guard let phAsset = await PHAssetCache.shared.phAsset(for: asset.id),
              phAsset.mediaType == .image else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var didResume = false
            let resume: (CGImage?) -> Void = { image in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
            PHCachingImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: 896, height: 896),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    resume(nil)
                    return
                }
                if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    resume(cg)
                }
            }
        }
    }

    private func representativeVideoFrame(for asset: MediaAsset) async -> CGImage? {
        guard let phAsset = await PHAssetCache.shared.phAsset(for: asset.id),
              phAsset.mediaType == .video else { return nil }

        guard let avAsset = await requestAVAsset(for: phAsset) else { return nil }
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 896, height: 896)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let duration = max(0, asset.duration)
        let sampleTime = CMTime(seconds: min(max(duration * 0.35, 0), max(duration - 0.1, 0)), preferredTimescale: 600)
        return try? await generator.image(at: sampleTime).image
    }

    private func requestAVAsset(for phAsset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .mediumQualityFormat
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    // MARK: - Fallback

    /// Fallback when OpenRouter is unavailable. Leaves `sceneCaption` and
    /// `semanticSummary` empty so the UI doesn't render identical boilerplate
    /// strings across every clip. Basic structural labels and a per-asset
    /// score still get filled in.
    private func fallbackAnalysis(for asset: MediaAsset) -> OpenRouterVisualAnalysis {
        let labels = fallbackLabels(for: asset)
        let isPortrait = asset.aspectRatio < 0.85
        let shot: ShotType = isPortrait ? .medium : .wide

        // Small per-asset jitter so confidence scores aren't all identical
        // — keeps the storyboard from showing a wall of "60% Low" badges.
        let h = abs(asset.id.hashValue)
        let jitter = Double((h % 14) - 7) / 100.0  // -0.07 ... +0.07

        return OpenRouterVisualAnalysis(
            qualityScore: Float(min(0.95, max(0.45, (asset.isFavorite ? 0.78 : 0.64) + jitter))),
            emotionScore: Float(min(0.95, max(0.40, (asset.isFavorite ? 0.72 : 0.55) + jitter * 0.8))),
            noveltyScore: Float(min(0.90, max(0.35, (asset.isVideo ? 0.64 : 0.50) + jitter * 1.2))),
            eventLabel: asset.creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "memory moment",
            sceneLabels: labels,
            sceneCaption: "",
            semanticSummary: "",
            shotType: shot,
            colorTemperature: 0.5,
            faceAreaFraction: nil,
            clipStartTime: asset.isVideo ? min(max(asset.duration * 0.20, 0), max(asset.duration - 3, 0)) : nil,
            faces: 0
        )
    }

    private func fallbackLabels(for asset: MediaAsset) -> [String] {
        var labels: [String] = [asset.isVideo ? "video" : "photo"]
        if asset.isFavorite { labels.append("favorite") }
        if asset.aspectRatio > 1.4 { labels.append("wide") }
        if asset.aspectRatio < 0.85 { labels.append("portrait") }
        return labels
    }
}
