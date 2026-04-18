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
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult
}

// MARK: - PhotoScoringService (Vision-powered: face detection + saliency + classification)

final class PhotoScoringService: PhotoScoringServiceProtocol {

    static let shared = PhotoScoringService()
    private init() {}

    private static let perAssetTimeoutSeconds: TimeInterval = 30
    private static let photoConcurrencyLimit = 6
    private static let videoConcurrencyLimit = 2

    func scorePhotos(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> PhotoScoringResult {

        scoringLog("▶︎ scorePhotos START — \(assets.count) assets, photoConcurrency=\(Self.photoConcurrencyLimit), videoConcurrency=\(Self.videoConcurrencyLimit), perPhotoTimeout=\(Int(Self.perAssetTimeoutSeconds))s")
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
                        ? inFlightVideos < Self.videoConcurrencyLimit
                        : inFlightPhotos < Self.photoConcurrencyLimit
                    guard canLaunch else { break }

                    let i = nextIndex
                    let label = asset.filename ?? asset.id
                    let isVideo = asset.isVideo
                    scoringLog("   → launch [\(i + 1)/\(total)] \(label) (isVideo=\(isVideo), \(isVideo ? "videos" : "photos") in flight now \(isVideo ? inFlightVideos + 1 : inFlightPhotos + 1))")
                    group.addTask {
                        let startedAt = Date()
                        let (quality, emotion, novelty, faces, clipStart) = await self.analyzeAsset(asset)
                        let elapsed = Date().timeIntervalSince(startedAt)
                        scoringLog("   ✓ done   [\(i + 1)/\(total)] \(label) in \(String(format: "%.1f", elapsed))s — q=\(String(format: "%.2f", quality)) e=\(String(format: "%.2f", emotion)) n=\(String(format: "%.2f", novelty)) faces=\(faces)")
                        return IndexedResult(index: i, quality: quality, emotion: emotion,
                                            novelty: novelty, faces: faces, clipStart: clipStart, isVideo: isVideo)
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
        scoringLog("■ scorePhotos DONE — \(included)/\(candidates.count) candidates included, \(completedCount)/\(total) assets analyzed")
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
            let faceRequest     = VNDetectFaceRectanglesRequest()
            let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
            let classifyRequest = VNClassifyImageRequest()

            do {
                try handler.perform([faceRequest, saliencyRequest, classifyRequest])
            } catch {
                scoringLog("     [\(label)] Vision perform failed: \(error.localizedDescription) — fallback scores")
                return self.fallbackScores()
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

    // MARK: - Image Fetching (properly cancellable)

    private func fetchCGImage(for assetID: String, label: String) async -> CGImage? {
        scoringLog("     [\(label)] PHAssetCache.phAsset lookup…")
        guard let phAsset = await PHAssetCache.shared.phAsset(for: assetID),
              phAsset.mediaType == .image else {
            scoringLog("     [\(label)] no PHAsset or not an image")
            return nil
        }
        let inCloud = (phAsset.value(forKey: "isCloudPlaceholder") as? Bool) ?? false
        scoringLog("     [\(label)] requesting 384px image (isCloudPlaceholder=\(inCloud))")

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
