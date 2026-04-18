import Foundation
import AVFoundation
import Vision
import Photos
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "video-analysis")

@inline(__always)
private func videoLog(_ message: @autoclosure () -> String) {
    let line = "[video] \(message())"
    print(line)
    fflush(stdout)
    logger.info("\(line, privacy: .public)")
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

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
}

// MARK: - VideoAnalysisService

final class VideoAnalysisService {

    static let shared = VideoAnalysisService()
    private init() {}

    func analyzeVideo(assetID: String, targetDuration: TimeInterval) async -> VideoAnalysisResult {
        videoLog("▶︎ analyzeVideo START assetID=\(assetID)")
        let result = await withTimeout(seconds: 90, fallback: fallback(), label: assetID) {
            await self.performAnalyzeVideo(assetID: assetID, targetDuration: targetDuration)
        }
        videoLog("■ analyzeVideo END   assetID=\(assetID)")
        return result
    }

    // MARK: - Internal analysis

    private func performAnalyzeVideo(assetID: String, targetDuration: TimeInterval) async -> VideoAnalysisResult {
        guard let phAsset = await PHAssetCache.shared.phAsset(for: assetID),
              phAsset.mediaType == .video else {
            videoLog("   [\(assetID)] no PHAsset or not a video — fallback")
            return fallback()
        }
        videoLog("   [\(assetID)] requesting AVAsset…")
        guard let avAsset = await requestAVAsset(for: phAsset) else {
            videoLog("   [\(assetID)] AVAsset unavailable — fallback")
            return fallback()
        }

        let totalSeconds: Double
        let loadedDuration = await withTimeout(seconds: 20, fallback: Optional<CMTime>.none, label: "\(assetID) duration") {
            try? await avAsset.load(.duration)
        }
        if let dur = loadedDuration {
            totalSeconds = CMTimeGetSeconds(dur)
            videoLog("   [\(assetID)] duration=\(String(format: "%.1f", totalSeconds))s")
        } else {
            videoLog("   [\(assetID)] duration load timed out — fallback")
            return fallback()
        }
        guard totalSeconds > 0 else { return fallback() }

        let maxSamples = 20
        let sampleInterval = max(totalSeconds / Double(maxSamples), 0.5)
        var sampleTimes: [CMTime] = []
        var t = 0.0
        while t < totalSeconds {
            sampleTimes.append(CMTime(seconds: t, preferredTimescale: 600))
            t += sampleInterval
        }
        videoLog("   [\(assetID)] sampling \(sampleTimes.count) frames every \(String(format: "%.2f", sampleInterval))s")

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.25, preferredTimescale: 600)

        struct FrameScore {
            var time: TimeInterval
            var q: Float; var e: Float; var n: Float
            var faces: Int
            var faceArea: Double
            var saliencyConf: Double
            var saliencyBbox: CGRect
            var colorTemperature: Double
        }

        let totalExpected = sampleTimes.count
        var frames: [FrameScore] = []
        var decoded = 0
        var failed = 0
        let logEvery = max(1, totalExpected / 4)

        for await result in generator.images(for: sampleTimes) {
            if Task.isCancelled {
                videoLog("   [\(assetID)] cancelled at frame \(decoded + failed)/\(totalExpected)")
                break
            }
            guard let cgImage = try? result.image else {
                failed += 1
                continue
            }
            decoded += 1
            let fs = await scoreFrame(cgImage)
            frames.append(FrameScore(
                time: CMTimeGetSeconds(result.requestedTime),
                q: fs.quality, e: fs.emotion, n: fs.novelty, faces: fs.faces,
                faceArea: fs.faceArea, saliencyConf: fs.saliencyConf,
                saliencyBbox: fs.saliencyBbox, colorTemperature: fs.colorTemperature
            ))

            if decoded % logEvery == 0 || decoded == totalExpected {
                videoLog("   [\(assetID)] frame \(decoded)/\(totalExpected) scored")
            }
        }

        if Task.isCancelled { return fallback() }
        if failed > 0 { videoLog("   [\(assetID)] \(failed) frame(s) failed to decode") }
        guard !frames.isEmpty else { return fallback() }

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

        let faceAreaFraction: Double? = {
            let maxArea = frames.map(\.faceArea).max() ?? 0.0
            return maxArea > 0 ? maxArea : nil
        }()

        let colorTemperature: Double = frames.map(\.colorTemperature).reduce(0, +) / Double(frames.count)

        let avgFaceArea = best.map(\.faceArea).reduce(0.0, +) / Double(best.count)
        let avgFaceCount = Double(best.map(\.faces).reduce(0, +)) / Double(best.count)
        let avgSaliencyConf = best.map(\.saliencyConf).reduce(0.0, +) / Double(best.count)
        let avgSaliencyBboxArea = best.map { Double($0.saliencyBbox.width * $0.saliencyBbox.height) }.reduce(0.0, +) / Double(best.count)

        let shotType: ShotType
        if avgFaceArea > 0.30 {
            shotType = .closeUp
        } else if avgFaceCount >= 3 {
            shotType = .group
        } else if avgFaceCount >= 1 {
            shotType = .medium
        } else if avgSaliencyConf > 0.7 && avgSaliencyBboxArea < 0.25 {
            shotType = .detail
        } else {
            shotType = .wide
        }

        let motionVector: MotionVector
        if best.count <= 1 {
            motionVector = MotionVector(dx: 0, dy: 0, magnitude: 0)
        } else {
            let firstBbox = best.first!.saliencyBbox
            let lastBbox  = best.last!.saliencyBbox
            let dx = Double(lastBbox.midX - firstBbox.midX)
            let dy = Double(lastBbox.midY - firstBbox.midY)
            motionVector = MotionVector(dx: dx, dy: dy, magnitude: min(1.0, hypot(dx, dy)))
        }

        let rawStart = frames[bestStart].time
        let safeStart = min(rawStart, max(0, totalSeconds - targetDuration))

        logger.info("[\(assetID)] Video analysis complete: \(frames.count) frames, duration \(String(format: "%.1f", totalSeconds))s")
        return VideoAnalysisResult(
            quality: avgQ, emotion: avgE, novelty: avgN, faces: maxF, bestStartTime: safeStart,
            shotType: shotType, motionVector: motionVector,
            colorTemperature: colorTemperature, faceAreaFraction: faceAreaFraction
        )
    }

    // MARK: - Timeout helper (does NOT await a hung op — returns promptly on timeout)

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        fallback: T,
        label: String,
        _ op: @Sendable @escaping () async -> T
    ) async -> T {
        let state = TimeoutState()

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
                    videoLog("   ⏱ TIMEOUT after \(Int(seconds))s on \(label) — cancelling and using fallback")
                    opTask.cancel()
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    // MARK: - Per-Frame Vision Scoring

    private func scoreFrame(_ cgImage: CGImage) async -> (quality: Float, emotion: Float, novelty: Float, faces: Int, faceArea: Double, saliencyConf: Double, saliencyBbox: CGRect, colorTemperature: Double) {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let faceReq     = VNDetectFaceRectanglesRequest()
        let saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()
        let classifyReq = VNClassifyImageRequest()

        guard (try? handler.perform([faceReq, saliencyReq, classifyReq])) != nil else {
            return (0.5, 0.4, 0.4, 0, 0.0, 0.5, CGRect(x: 0, y: 0, width: 1, height: 1), 0.5)
        }

        let faces = faceReq.results ?? []
        let faceCount = faces.count
        let avgFaceConf: Float = faceCount > 0
            ? faces.map(\.confidence).reduce(0, +) / Float(faceCount) : 0

        let saliencyObs  = saliencyReq.results?.first
        let saliencyConf = Double(saliencyObs?.confidence ?? 0.5)
        let saliencyBbox: CGRect = saliencyObs?.salientObjects?.first?.boundingBox
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        let topConfSum   = (classifyReq.results ?? []).prefix(3).map { Float($0.confidence) }.reduce(0, +)

        let quality = min(1.0, Float(saliencyConf) * 0.65 + avgFaceConf * 0.2 + 0.15)
        let emotion = faceCount > 0
            ? min(1.0, 0.45 + Float(faceCount) * 0.15 + avgFaceConf * 0.3)
            : min(0.72, Float(saliencyConf) * 0.5 + 0.2)
        let novelty = min(1.0, max(0.2, 1.0 - topConfSum * 0.55))

        let faceArea = faces
            .map { Double($0.boundingBox.width * $0.boundingBox.height) }
            .max() ?? 0.0

        let colorTemperature = computeColorTemperature(from: cgImage)

        return (quality, emotion, novelty, faceCount, faceArea, saliencyConf, saliencyBbox, colorTemperature)
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

    // MARK: - PHAsset → AVAsset

    private func requestAVAsset(for phAsset: PHAsset) async -> AVAsset? {
        final class RequestIDBox: @unchecked Sendable {
            var id: PHImageRequestID = PHInvalidImageRequestID
        }
        let box = RequestIDBox()

        let result = await withTimeout(seconds: 60, fallback: AVAsset?.none, label: "\(phAsset.localIdentifier) AVAsset") {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<AVAsset?, Never>) in
                    let options = PHVideoRequestOptions()
                    options.isNetworkAccessAllowed = true
                    options.deliveryMode = .fastFormat
                    var resumed = false
                    box.id = PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: avAsset)
                    }
                }
            } onCancel: {
                PHImageManager.default().cancelImageRequest(box.id)
            }
        }

        if result == nil {
            logger.warning("requestAVAsset timed out for asset \(phAsset.localIdentifier)")
        }
        return result
    }

    // MARK: - Fallback

    private func fallback() -> VideoAnalysisResult {
        VideoAnalysisResult(
            quality:          Float.random(in: 0.50...0.85),
            emotion:          Float.random(in: 0.35...0.75),
            novelty:          Float.random(in: 0.30...0.70),
            faces:            0,
            bestStartTime:    0,
            shotType:         nil,
            motionVector:     nil,
            colorTemperature: nil,
            faceAreaFraction: nil
        )
    }
}
