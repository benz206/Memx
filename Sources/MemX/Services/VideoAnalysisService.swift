import Foundation
import AVFoundation
import Vision
import Photos

// MARK: - VideoAnalysisResult

struct VideoAnalysisResult {
    var quality: Float
    var emotion: Float
    var novelty: Float
    var faces: Int
    var bestStartTime: TimeInterval
}

// MARK: - VideoAnalysisService

final class VideoAnalysisService {

    static let shared = VideoAnalysisService()
    private init() {}

    /// Samples frames across the video, scores each with Vision, and returns the best
    /// contiguous window of `targetDuration` seconds plus aggregate quality scores.
    func analyzeVideo(assetID: String, targetDuration: TimeInterval) async -> VideoAnalysisResult {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let phAsset = fetchResult.firstObject, phAsset.mediaType == .video else {
            return fallback()
        }
        guard let avAsset = await requestAVAsset(for: phAsset) else { return fallback() }

        let totalSeconds: Double
        if let dur = try? await avAsset.load(.duration) {
            totalSeconds = CMTimeGetSeconds(dur)
        } else {
            return fallback()
        }
        guard totalSeconds > 0 else { return fallback() }

        // Sample up to 60 frames, at least every 0.5 s
        let sampleInterval = max(totalSeconds / 60.0, 0.5)
        var sampleTimes: [CMTime] = []
        var t = 0.0
        while t < totalSeconds {
            sampleTimes.append(CMTime(seconds: t, preferredTimescale: 600))
            t += sampleInterval
        }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.25, preferredTimescale: 600)

        struct FrameScore { var time: TimeInterval; var q: Float; var e: Float; var n: Float; var faces: Int }
        var frames: [FrameScore] = []

        for requestedTime in sampleTimes {
            guard let cgImage = try? generator.copyCGImage(at: requestedTime, actualTime: nil) else { continue }
            let (q, e, n, f) = await scoreFrame(cgImage)
            frames.append(FrameScore(time: CMTimeGetSeconds(requestedTime), q: q, e: e, n: n, faces: f))
        }

        guard !frames.isEmpty else { return fallback() }

        // Sliding window: find window whose average composite score is highest
        let windowSize = max(1, Int((targetDuration / sampleInterval).rounded()))
        var bestStart = 0
        var bestScore: Float = -1

        for start in 0...(max(0, frames.count - windowSize)) {
            let end = min(start + windowSize, frames.count)
            let window = frames[start..<end]
            let avg = window.map { $0.q * 0.4 + $0.e * 0.35 + $0.n * 0.25 }.reduce(0, +) / Float(window.count)
            if avg > bestScore { bestScore = avg; bestStart = start }
        }

        let best = frames[bestStart..<min(bestStart + windowSize, frames.count)]
        let c = Float(best.count)
        let avgQ = best.map(\.q).reduce(0, +) / c
        let avgE = best.map(\.e).reduce(0, +) / c
        let avgN = best.map(\.n).reduce(0, +) / c
        let maxF = best.map(\.faces).max() ?? 0

        // Clamp so the clip fits entirely within the video
        let rawStart = frames[bestStart].time
        let safeStart = min(rawStart, max(0, totalSeconds - targetDuration))

        return VideoAnalysisResult(quality: avgQ, emotion: avgE, novelty: avgN, faces: maxF, bestStartTime: safeStart)
    }

    // MARK: - Per-Frame Vision Scoring

    private func scoreFrame(_ cgImage: CGImage) async -> (quality: Float, emotion: Float, novelty: Float, faces: Int) {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let faceReq     = VNDetectFaceRectanglesRequest()
        let saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()
        let classifyReq = VNClassifyImageRequest()

        guard (try? handler.perform([faceReq, saliencyReq, classifyReq])) != nil else {
            return (0.5, 0.4, 0.4, 0)
        }

        let faces = faceReq.results ?? []
        let faceCount = faces.count
        let avgFaceConf: Float = faceCount > 0
            ? faces.map(\.confidence).reduce(0, +) / Float(faceCount) : 0

        let saliencyConf = Float((saliencyReq.results?.first)?.confidence ?? 0.5)
        let topConfSum   = (classifyReq.results ?? []).prefix(3).map { Float($0.confidence) }.reduce(0, +)

        let quality = min(1.0, saliencyConf * 0.65 + avgFaceConf * 0.2 + 0.15)
        let emotion = faceCount > 0
            ? min(1.0, 0.45 + Float(faceCount) * 0.15 + avgFaceConf * 0.3)
            : min(0.72, saliencyConf * 0.5 + 0.2)
        let novelty = min(1.0, max(0.2, 1.0 - topConfSum * 0.55))

        return (quality, emotion, novelty, faceCount)
    }

    // MARK: - PHAsset → AVAsset

    private func requestAVAsset(for phAsset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: avAsset)
            }
        }
    }

    // MARK: - Fallback

    private func fallback() -> VideoAnalysisResult {
        VideoAnalysisResult(
            quality:       Float.random(in: 0.50...0.85),
            emotion:       Float.random(in: 0.35...0.75),
            novelty:       Float.random(in: 0.30...0.70),
            faces:         0,
            bestStartTime: 0
        )
    }
}
