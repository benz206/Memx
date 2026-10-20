import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import Photos
import Vision

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

// MARK: - VisualAnalysis

struct VisualAnalysis {
    var qualityScore: Float
    var emotionScore: Float
    var noveltyScore: Float
    var eventLabel: String?
    var sceneLabels: [String]
    var sceneCaption: String
    var semanticSummary: String
    var shotType: ShotType
    var colorTemperature: Double
    var faceAreaFraction: Double?
    var clipStartTime: TimeInterval?
    var faces: Int
    var motionEnergy: Float
    var isUtility: Bool
    var focusPoint: FocusPoint?
}

struct VisionReadout {
    var aesthetic: Float?
    var aestheticsSaysUtility = false
    var identifiers: [String] = []
    var faceCount = 0
    var largestFaceArea = 0.0
    var bestFaceQuality: Float?
    var focusPoint: FocusPoint?
}

// MARK: - PhotoScoringService

/// Fully on-device visual analysis: fetch a downscaled photo or
/// representative video frame, compute a Vision FeaturePrint (the visual
/// embedding the sequencer uses for match-cut continuity between adjacent
/// clips), and derive per-asset scores from the asset's own metadata.
final class PhotoScoringService: PhotoScoringServiceProtocol {

    static let shared = PhotoScoringService()

    private init() {}

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
        scoringLog("▶︎ on-device scorePhotos START — \(assets.count) assets, density=\(density.rawValue), concurrency=\(maxConcurrent)")
        onProgress(0.03, "Preparing \(assets.count) assets for on-device analysis...")

        struct IndexedResult {
            let index: Int
            let analysis: VisualAnalysis
            let visualEmbedding: [Float]?
            let motionSamples: [Float]?
        }

        let pending = assets.indices.filter { assets[$0].analysisVersion != VisualSignals.analysisVersion }
        var results = [IndexedResult?](repeating: nil, count: assets.count)
        var completed = 0

        try await withThrowingTaskGroup(of: IndexedResult.self) { group in
            var nextSlot = 0

            func launch(_ index: Int) {
                let asset = assets[index]
                group.addTask {
                    try Task.checkCancellation()
                    let image = asset.isVideo
                        ? await self.representativeVideoFrame(for: asset)
                        : await self.photoImage(for: asset)
                    let embedding = image.flatMap { Self.featurePrintEmbedding(for: $0) }
                    let motionSamples = asset.isVideo ? await self.motionSeries(for: asset) : nil
                    var readout: VisionReadout? = nil
                    if let image { readout = await Self.visionReadout(for: image) }
                    var analysis = self.localAnalysis(for: asset, vision: readout, motionSamples: motionSamples)
                    if let image, let warmth = Self.colorTemperature(for: image) {
                        analysis.colorTemperature = warmth
                    }
                    return IndexedResult(index: index, analysis: analysis,
                                         visualEmbedding: embedding, motionSamples: motionSamples)
                }
            }

            while nextSlot < min(maxConcurrent, pending.count) {
                launch(pending[nextSlot])
                nextSlot += 1
            }

            while let result = try await group.next() {
                results[result.index] = result
                completed += 1
                let progress = Double(completed) / Double(max(pending.count, 1))
                onProgress(0.05 + progress * 0.90, "Analyzed \(completed)/\(pending.count) on-device...")

                if nextSlot < pending.count {
                    launch(pending[nextSlot])
                    nextSlot += 1
                }
            }
        }

        onProgress(0.96, "Ranking storyboard candidates...")

        var scoredAssets = assets

        for result in results.compactMap({ $0 }) {
            let a = result.analysis
            scoredAssets[result.index].qualityScore = a.qualityScore
            scoredAssets[result.index].emotionScore = a.emotionScore
            scoredAssets[result.index].sceneLabels = a.sceneLabels.isEmpty ? nil : a.sceneLabels
            scoredAssets[result.index].sceneCaption = a.sceneCaption.isEmpty ? nil : a.sceneCaption
            scoredAssets[result.index].semanticSummary = a.semanticSummary.isEmpty ? nil : a.semanticSummary
            scoredAssets[result.index].shotType = a.shotType
            scoredAssets[result.index].colorTemperature = a.colorTemperature
            scoredAssets[result.index].faceAreaFraction = a.faceAreaFraction
            scoredAssets[result.index].clipStartTime = a.clipStartTime
            scoredAssets[result.index].motionEnergy = a.motionEnergy
            scoredAssets[result.index].visualEmbedding = result.visualEmbedding
            scoredAssets[result.index].motionSamples = result.motionSamples
            scoredAssets[result.index].isUtility = a.isUtility
            scoredAssets[result.index].faceCount = a.faces
            scoredAssets[result.index].focusPoint = a.focusPoint
            scoredAssets[result.index].analysisVersion = VisualSignals.analysisVersion
        }

        Self.applyPoolSignals(to: &scoredAssets)

        let candidates: [ClipCandidate] = scoredAssets.compactMap { asset in
            guard let score = asset.analysisScore else { return nil }
            return ClipCandidate(
                assetID: asset.id,
                overallScore: score,
                qualityScore: asset.qualityScore ?? 0.65,
                emotionScore: asset.emotionScore ?? 0.55,
                noveltyScore: asset.noveltyScore ?? 0.50,
                faces: asset.faceCount ?? 0,
                isIncluded: score > 0.35
            )
        }

        let included = candidates.filter(\.isIncluded).count
        scoringLog("■ on-device scorePhotos DONE — \(included)/\(candidates.count) candidates included")
        onProgress(1.0, "Visual analysis complete")
        return PhotoScoringResult(scoredAssets: scoredAssets, candidates: candidates)
    }

    static func applyPoolSignals(to assets: inout [MediaAsset]) {
        let novelty = VisualSignals.noveltyScores(assets.map(\.visualEmbedding))
        let events = VisualSignals.eventLabels(dates: assets.map(\.creationDate),
                                               locations: assets.map(\.location))
        for i in assets.indices {
            guard assets[i].analysisVersion == VisualSignals.analysisVersion else { continue }
            let n = novelty[i] ?? (assets[i].isVideo ? 0.64 : 0.5)
            assets[i].noveltyScore = n
            assets[i].eventLabel = events[i] ?? "memory moment"
            assets[i].analysisScore = (assets[i].isUtility ?? false)
                ? 0.1
                : VisualSignals.overallScore(quality: assets[i].qualityScore ?? 0.6,
                                             emotion: assets[i].emotionScore ?? 0.5,
                                             novelty: n)
        }
    }

    static func visionReadout(for image: CGImage) async -> VisionReadout {
        var readout = VisionReadout()

        if let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image) {
            readout.aesthetic = aesthetics.overallScore
            readout.aestheticsSaysUtility = aesthetics.isUtility
        }

        if let classes = try? await ClassifyImageRequest().perform(on: image) {
            readout.identifiers = classes
                .filter { $0.confidence >= 0.1 && $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
                .sorted { $0.confidence > $1.confidence }
                .map(\.identifier)
        }

        let faces = (try? await DetectFaceCaptureQualityRequest().perform(on: image)) ?? []
        readout.faceCount = faces.count
        if !faces.isEmpty {
            readout.largestFaceArea = faces
                .map { Double($0.boundingBox.width * $0.boundingBox.height) }
                .max() ?? 0
            readout.bestFaceQuality = faces.compactMap { $0.captureQuality?.score }.max()
            let union = faces.map(\.boundingBox.cgRect).reduce(CGRect.null) { $0.union($1) }
            readout.focusPoint = FocusPoint(x: Double(union.midX), y: Double(1 - union.midY))
        } else if let saliency = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image),
                  let main = saliency.salientObjects.max(by: {
                      $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
                  }) {
            let box = main.boundingBox.cgRect
            readout.focusPoint = FocusPoint(x: Double(box.midX), y: Double(1 - box.midY))
        }
        return readout
    }

    // MARK: - Visual Embedding (Vision FeaturePrint, on-device)

    static func featurePrintEmbedding(for image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementType == .float,
              observation.elementCount > 0 else { return nil }

        var vector = observation.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in vector.indices { vector[i] /= norm }
        return vector
    }

    // MARK: - Color Temperature (on-device)

    /// Approximate warmth of a frame (0 cool … 1 warm) from the red/blue
    /// balance of a tiny downsample. The 1.5 spread puts golden-hour and
    /// blue-shade frames far enough apart that the sequencer's warmth
    /// matching and color-jump transition trigger actually discriminate.
    static func colorTemperature(for image: CGImage) -> Double? {
        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(side * side) {
            r += Double(pixels[i * 4])
            g += Double(pixels[i * 4 + 1])
            b += Double(pixels[i * 4 + 2])
        }
        let warmth = 0.5 + 1.5 * (r - b) / max(r + g + b, 1e-6)
        return min(1, max(0, warmth))
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

    // MARK: - Motion Series (frame differencing)
    // Coarse motion energy over time: N+1 tiny grayscale frames at uniform
    // times, mean absolute difference between consecutive pairs. Sample m
    // covers (m+0.5)·duration/N — the mapping motionPeakTime(in:) relies on.
    // This is what lets the sequencer put the jump/splash frame on the beat
    // instead of guessing the action sits mid-clip.

    private static let motionSampleCount = 16

    private func motionSeries(for asset: MediaAsset) async -> [Float]? {
        guard asset.duration > 0.5,
              let phAsset = await PHAssetCache.shared.phAsset(for: asset.id),
              phAsset.mediaType == .video,
              let avAsset = await requestAVAsset(for: phAsset) else { return nil }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let tolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = Self.motionSampleCount
        let step = asset.duration / Double(count)
        var frames = [[Float]]()
        frames.reserveCapacity(count + 1)
        for i in 0...count {
            let t = min(Double(i) * step, max(asset.duration - 0.1, 0))
            guard let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                  let gray = Self.grayscalePixels(cg, side: 24) else { return nil }
            frames.append(gray)
        }

        var samples = [Float]()
        samples.reserveCapacity(count)
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            guard a.count == b.count else { return nil }
            var sum: Float = 0
            for k in a.indices { sum += abs(a[k] - b[k]) }
            // ~0.12 mean per-pixel change between samples reads as full
            // action; the fixed scale keeps values comparable across videos.
            samples.append(min(1, (sum / Float(a.count)) * 8))
        }
        return samples
    }

    private static func grayscalePixels(_ image: CGImage, side: Int) -> [Float]? {
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        return (0..<(side * side)).map { Float(pixels[$0]) / 255.0 }
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

    // MARK: - Local Analysis

    func localAnalysis(for asset: MediaAsset, vision: VisionReadout?,
                       motionSamples: [Float]?) -> VisualAnalysis {
        let v = vision ?? VisionReadout()
        let isUtility = VisualSignals.isUtility(identifiers: v.identifiers,
                                                aestheticsSaysUtility: v.aestheticsSaysUtility)

        var motion = asset.isVideo ? Float(0.55) : VisualSignals.photoMotionEnergy(faceCount: v.faceCount, identifiers: v.identifiers)
        if let samples = motionSamples, !samples.isEmpty {
            // Measured motion beats the metadata heuristic when we have it.
            let mean = samples.reduce(0, +) / Float(samples.count)
            let peak = samples.max() ?? mean
            motion = min(1, mean * 0.6 + peak * 0.4)
        }

        return VisualAnalysis(
            qualityScore: VisualSignals.qualityScore(aesthetic: v.aesthetic, isUtility: isUtility,
                                                     bestFaceQuality: v.bestFaceQuality,
                                                     isFavorite: asset.isFavorite),
            emotionScore: VisualSignals.emotionScore(faceCount: v.faceCount, identifiers: v.identifiers,
                                                     isFavorite: asset.isFavorite),
            noveltyScore: asset.isVideo ? 0.64 : 0.5,
            eventLabel: nil,
            sceneLabels: VisualSignals.displayLabels(v.identifiers),
            sceneCaption: "",
            semanticSummary: "",
            shotType: VisualSignals.shotType(faceCount: v.faceCount, largestFaceArea: v.largestFaceArea,
                                             identifiers: v.identifiers, isVideo: asset.isVideo,
                                             motionEnergy: motion),
            colorTemperature: 0.5,
            faceAreaFraction: v.faceCount > 0 ? v.largestFaceArea : nil,
            clipStartTime: asset.isVideo ? min(max(asset.duration * 0.20, 0), max(asset.duration - 3, 0)) : nil,
            faces: v.faceCount,
            motionEnergy: motion,
            isUtility: isUtility,
            focusPoint: v.focusPoint
        )
    }
}
