import Foundation
import Vision
import Photos
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "scoring")

@inline(__always)
private func scoringLog(_ message: @autoclosure () -> String) {
    let line = "[scoring] \(message())"
    print(line)
    fflush(stdout)
    logger.info("\(line, privacy: .public)")
}

private final class ScoringTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
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

// MARK: - PhotoScoringService (Vision-powered: face detection + saliency + classification)

final class PhotoScoringService: PhotoScoringServiceProtocol {

    static let shared = PhotoScoringService()
    private init() {}

    private static let perAssetTimeoutSeconds: TimeInterval = 30

    /// Concurrency caps derived from density. Cheaper-per-asset densities can
    /// parallelize more; heavier densities run fewer concurrently to avoid
    /// overcommitting the CPU/GPU.
    private static func concurrencyLimits(for density: ScoringDensity) -> (photo: Int, video: Int) {
        switch density {
        case .verySparse, .sparse: return (8, 3)
        case .balanced:            return (6, 2)
        case .dense, .veryDense:   return (4, 1)
        }
    }

    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        density: ScoringDensity = .balanced,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult {

        let limits = Self.concurrencyLimits(for: density)
        let photoConcurrencyLimit = limits.photo
        let videoConcurrencyLimit = limits.video

        scoringLog("▶︎ scorePhotos START — \(assets.count) assets, density=\(density.rawValue), photoConcurrency=\(photoConcurrencyLimit), videoConcurrency=\(videoConcurrencyLimit), perPhotoTimeout=\(Int(Self.perAssetTimeoutSeconds))s")
        onProgress(0.05, "Preparing \(assets.count) photos for analysis...")

        let total = assets.count

        struct IndexedResult {
            let index: Int
            let quality: Float
            let emotion: Float
            let novelty: Float
            let faces: Int
            let clipStart: TimeInterval?
            let isVideo: Bool
            let shotType: ShotType?
            let motionVector: MotionVector?
            let colorTemperature: Double?
            let faceAreaFraction: Double?
            let sceneLabels: [String]?
            let sceneCaption: String?
        }

        var results = [IndexedResult?](repeating: nil, count: total)
        var completedCount = 0

        try await withThrowingTaskGroup(of: IndexedResult.self) { group in
            var inFlightPhotos = 0
            var inFlightVideos = 0
            var nextIndex = 0

            while nextIndex < total || (inFlightPhotos + inFlightVideos) > 0 {
                try Task.checkCancellation()

                while nextIndex < total {
                    let asset = assets[nextIndex]
                    let canLaunch = asset.isVideo
                        ? inFlightVideos < videoConcurrencyLimit
                        : inFlightPhotos < photoConcurrencyLimit
                    guard canLaunch else { break }

                    let i = nextIndex
                    let label = asset.filename ?? asset.id
                    let isVideo = asset.isVideo
                    scoringLog("   → launch [\(i + 1)/\(total)] \(label) (isVideo=\(isVideo), \(isVideo ? "videos" : "photos") in flight now \(isVideo ? inFlightVideos + 1 : inFlightPhotos + 1))")
                    group.addTask {
                        let startedAt = Date()
                        let r = await self.analyzeAsset(asset, density: density)
                        let elapsed = Date().timeIntervalSince(startedAt)
                        scoringLog("   ✓ done   [\(i + 1)/\(total)] \(label) in \(String(format: "%.1f", elapsed))s — q=\(String(format: "%.2f", r.quality)) e=\(String(format: "%.2f", r.emotion)) n=\(String(format: "%.2f", r.novelty)) faces=\(r.faces)")
                        return IndexedResult(index: i, quality: r.quality, emotion: r.emotion,
                                            novelty: r.novelty, faces: r.faces, clipStart: r.clipStartTime,
                                            isVideo: isVideo, shotType: r.shotType, motionVector: r.motionVector,
                                            colorTemperature: r.colorTemperature, faceAreaFraction: r.faceAreaFraction,
                                            sceneLabels: r.sceneLabels, sceneCaption: r.sceneCaption)
                    }
                    onProgress(0.05 + Double(nextIndex) / Double(total) * 0.04,
                               "Starting \(nextIndex + 1)/\(total)…")
                    if isVideo { inFlightVideos += 1 } else { inFlightPhotos += 1 }
                    nextIndex += 1
                }

                if let result = try await group.next() {
                    results[result.index] = result
                    if result.isVideo { inFlightVideos -= 1 } else { inFlightPhotos -= 1 }
                    completedCount += 1
                    let progress = Double(completedCount) / Double(max(total, 1))
                    onProgress(0.05 + progress * 0.87,
                               "Analyzed \(completedCount)/\(total) — \(inFlightPhotos) photos, \(inFlightVideos) videos in flight")
                }
            }
        }

        onProgress(0.95, "Ranking candidates...")

        var scoredAssets = assets
        var faceCounts = [Int](repeating: 0, count: total)
        for r in results.compactMap({ $0 }) {
            let overall = r.quality * 0.4 + r.emotion * 0.35 + r.novelty * 0.25
            scoredAssets[r.index].qualityScore     = r.quality
            scoredAssets[r.index].emotionScore     = r.emotion
            scoredAssets[r.index].noveltyScore     = r.novelty
            scoredAssets[r.index].analysisScore    = overall
            scoredAssets[r.index].clipStartTime    = r.clipStart
            scoredAssets[r.index].shotType         = r.shotType
            scoredAssets[r.index].motionVector     = r.motionVector
            scoredAssets[r.index].colorTemperature = r.colorTemperature
            scoredAssets[r.index].faceAreaFraction = r.faceAreaFraction
            scoredAssets[r.index].sceneLabels      = r.sceneLabels
            scoredAssets[r.index].sceneCaption     = r.sceneCaption
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
        scoringLog("■ scorePhotos DONE — \(included)/\(candidates.count) candidates included, \(completedCount)/\(total) assets analyzed")
        onProgress(1.0, "Photo scoring complete")
        return PhotoScoringResult(scoredAssets: scoredAssets, candidates: candidates)
    }

    // MARK: - Per-Asset Vision Analysis

    private func analyzeAsset(_ asset: MediaAsset, density: ScoringDensity) async -> (quality: Float, emotion: Float, novelty: Float, faces: Int, clipStartTime: TimeInterval?, shotType: ShotType?, motionVector: MotionVector?, colorTemperature: Double?, faceAreaFraction: Double?, sceneLabels: [String]?, sceneCaption: String?) {
        if asset.isVideo {
            let result = await VideoAnalysisService.shared.analyzeVideo(
                assetID: asset.id,
                targetDuration: 3.0,
                density: density
            )
            return (result.quality, result.emotion, result.novelty, result.faces, result.bestStartTime,
                    result.shotType, result.motionVector, result.colorTemperature, result.faceAreaFraction,
                    result.sceneLabels, result.sceneCaption)
        }

        let label = asset.filename ?? asset.id
        return await withAssetTimeout(
            seconds: Self.perAssetTimeoutSeconds,
            fallback: fallbackScores(),
            label: label
        ) {
            guard let cgImage = await self.fetchCGImage(for: asset.id, label: label) else {
                scoringLog("     [\(label)] no image available — fallback scores")
                return self.fallbackScores()
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            // Density-tuned Vision request set:
            //   verySparse/sparse → skip VNClassifyImageRequest (it's the slowest).
            //   dense/veryDense   → run face rectangles AND face landmarks (heavier, better emotion signal).
            //   balanced          → rectangles + saliency + classify (original behavior).
            let faceRectRequest    = VNDetectFaceRectanglesRequest()
            let faceLandmarksReq   = VNDetectFaceLandmarksRequest()
            let saliencyRequest    = VNGenerateAttentionBasedSaliencyImageRequest()
            let classifyRequest    = VNClassifyImageRequest()

            let runClassify = (density == .balanced || density == .dense || density == .veryDense)
            let runLandmarks = (density == .dense || density == .veryDense)

            var requests: [VNRequest] = [faceRectRequest, saliencyRequest]
            if runClassify { requests.append(classifyRequest) }
            if runLandmarks { requests.append(faceLandmarksReq) }

            do {
                try handler.perform(requests)
            } catch {
                scoringLog("     [\(label)] Vision perform failed: \(error.localizedDescription) — fallback scores")
                return self.fallbackScores()
            }

            let rectFaces = faceRectRequest.results ?? []
            let landmarkFaces = runLandmarks ? (faceLandmarksReq.results ?? []) : []
            // Prefer landmark observations when available (carry richer confidence).
            let faces: [VNFaceObservation] = landmarkFaces.isEmpty ? rectFaces : landmarkFaces
            let faceCount = faces.count
            let avgFaceConf: Float = faceCount > 0
                ? faces.map(\.confidence).reduce(0, +) / Float(faceCount) : 0

            let saliencyConf = Float((saliencyRequest.results?.first)?.confidence ?? 0.5)
            let classifyResults = runClassify ? (classifyRequest.results ?? []) : []
            let topConfSum: Float = runClassify
                ? classifyResults.prefix(3).map { Float($0.confidence) }.reduce(0, +)
                : 0
            // Keep the top N labels as human-readable tags for the UI and
            // for downstream prompt context. We only surface labels whose
            // confidence clears a floor so we don't leak noise.
            let sceneLabels: [String] = classifyResults
                .prefix(5)
                .filter { $0.confidence > 0.15 }
                .map(\.identifier)

            let quality = min(1.0, saliencyConf * 0.65 + avgFaceConf * 0.2 + 0.15)
            let emotion = faceCount > 0
                ? min(1.0, 0.45 + Float(faceCount) * 0.15 + avgFaceConf * 0.3)
                : min(0.72, saliencyConf * 0.5 + 0.2)
            // When classify is skipped, default to a neutral novelty so we don't
            // punish the asset for the missing signal.
            let novelty: Float = runClassify
                ? min(1.0, max(0.2, 1.0 - topConfSum * 0.55))
                : 0.5

            let faceAreaFraction: Double? = faces
                .map { Double($0.boundingBox.width * $0.boundingBox.height) }
                .max()
                .flatMap { $0 > 0 ? $0 : nil }

            let saliencyBboxArea: Double = {
                if let bbox = (saliencyRequest.results?.first)?.salientObjects?.first?.boundingBox {
                    return Double(bbox.width * bbox.height)
                }
                return 1.0
            }()

            let shotType: ShotType
            if let fa = faceAreaFraction, fa > 0.30 {
                shotType = .closeUp
            } else if faceCount >= 3 {
                shotType = .group
            } else if faceCount >= 1 {
                shotType = .medium
            } else if Double(saliencyConf) > 0.7 && saliencyBboxArea < 0.25 {
                shotType = .detail
            } else {
                shotType = .wide
            }

            let colorTemperature = self.computeColorTemperature(from: cgImage)

            // Generate a caption via Apple Intelligence if available. The
            // service is guarded by an 8 s internal timeout and returns nil
            // gracefully if FoundationModels is unavailable.
            let sceneCaption: String? = !sceneLabels.isEmpty
                ? await SceneCaptionService.shared.caption(for: cgImage, sceneLabels: sceneLabels)
                : nil

            return (quality, emotion, novelty, faceCount, nil, shotType,
                    MotionVector(dx: 0, dy: 0, magnitude: 0), colorTemperature, faceAreaFraction,
                    sceneLabels.isEmpty ? nil : sceneLabels, sceneCaption)
        }
    }

    private func computeColorTemperature(from cgImage: CGImage) -> Double {
        let size = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        var totalR: Double = 0
        var totalB: Double = 0
        for i in 0..<(size * size) {
            totalR += Double(pixels[i * 4])
            totalB += Double(pixels[i * 4 + 2])
        }
        let count = Double(size * size)
        return min(1.0, max(0.0, 0.5 + (totalR / count - totalB / count) / 255.0))
    }

    private func fallbackScores() -> (Float, Float, Float, Int, TimeInterval?, ShotType?, MotionVector?, Double?, Double?, [String]?, String?) {
        (
            Float.random(in: 0.50...0.88),
            Float.random(in: 0.35...0.78),
            Float.random(in: 0.30...0.75),
            0,
            nil, nil, nil, nil, nil, nil, nil
        )
    }

    // MARK: - Image Fetching (properly cancellable)

    private func fetchCGImage(for assetID: String, label: String) async -> CGImage? {
        scoringLog("     [\(label)] PHAssetCache.phAsset lookup…")
        guard let phAsset = await PHAssetCache.shared.phAsset(for: assetID),
              phAsset.mediaType == .image else {
            scoringLog("     [\(label)] no PHAsset or not an image")
            return nil
        }
        scoringLog("     [\(label)] requesting 384px image")

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        final class RequestIDBox: @unchecked Sendable {
            let lock = NSLock()
            var id: PHImageRequestID = PHInvalidImageRequestID
            func set(_ newID: PHImageRequestID) { lock.lock(); id = newID; lock.unlock() }
            func get() -> PHImageRequestID { lock.lock(); defer { lock.unlock() }; return id }
        }
        let box = RequestIDBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                let resumeLock = NSLock()
                var resumed = false
                let resume: (CGImage?) -> Void = { img in
                    resumeLock.lock()
                    let shouldResume = !resumed
                    resumed = true
                    resumeLock.unlock()
                    if shouldResume { continuation.resume(returning: img) }
                }

                let id = PHImageManager.default().requestImage(
                    for: phAsset,
                    targetSize: CGSize(width: 384, height: 384),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if let image = image {
                        resume(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                        return
                    }
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        scoringLog("     [\(label)] PHImage request cancelled by Photos")
                        resume(nil); return
                    }
                    if let err = info?[PHImageErrorKey] as? Error {
                        scoringLog("     [\(label)] PHImage error: \(err.localizedDescription)")
                        resume(nil); return
                    }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded { resume(nil) }
                }
                box.set(id)
            }
        } onCancel: {
            let id = box.get()
            if id != PHInvalidImageRequestID {
                scoringLog("     [\(label)] task cancelled — cancelling PHImage request \(id)")
                PHImageManager.default().cancelImageRequest(id)
            }
        }
    }

    // MARK: - Per-asset timeout that actually returns (does not await hung op)

    private func withAssetTimeout<T: Sendable>(
        seconds: TimeInterval,
        fallback: T,
        label: String,
        _ op: @Sendable @escaping () async -> T
    ) async -> T {
        let state = ScoringTimeoutState()

        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let opTask = Task<Void, Never> {
                let value = await op()
                if state.claim() {
                    continuation.resume(returning: value)
                }
            }
            Task<Void, Never> {
                try? await Task.sleep(for: .seconds(seconds))
                if state.claim() {
                    scoringLog("   ⏱ TIMEOUT after \(Int(seconds))s on \(label) — cancelling work and using fallback")
                    opTask.cancel()
                    continuation.resume(returning: fallback)
                }
            }
        }
    }
}
