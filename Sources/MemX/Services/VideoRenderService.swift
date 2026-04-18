import Foundation
import AVFoundation
import Photos
import CoreGraphics
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "render")

// MARK: - VideoRenderServiceProtocol

protocol VideoRenderServiceProtocol {
    func render(
        plan: MontagePlan,
        songURL: URL,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> URL
}

// MARK: - VideoRenderService (AVMutableComposition + AVAssetExportSession)

final class VideoRenderService: VideoRenderServiceProtocol {

    static let shared = VideoRenderService()
    private init() {}

    private let renderSize  = CGSize(width: 1920, height: 1080)
    private let timescale: CMTimeScale = 600
    private let fps: Int32  = 30

    // MARK: - Public Entry Point

    func render(
        plan: MontagePlan,
        songURL: URL,
        assets: [MediaAsset],
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let sequence = plan.sequence
        guard !sequence.isEmpty else { throw RenderError.emptySequence }

        logger.info("Render started: \(sequence.count) clips, song=\(songURL.lastPathComponent)")
        onProgress(0.02, "Exporting \(sequence.count) clips…")

        // Step 1 — Convert each clip to a temp video URL
        var clipURLs: [URL] = []
        for (i, item) in sequence.enumerated() {
            let clipDuration = CMTime(seconds: item.duration, preferredTimescale: timescale)

            let url: URL
            if let asset = assetMap[item.assetID], asset.isVideo {
                do {
                    url = try await exportVideoClip(assetID: item.assetID, startTime: item.clipOffset, duration: item.duration)
                } catch {
                    logger.warning("Video export failed for \(item.assetID), falling back to thumbnail: \(error)")
                    url = try await exportPhotoClip(assetID: item.assetID, duration: clipDuration)
                }
            } else {
                url = try await exportPhotoClip(assetID: item.assetID, duration: clipDuration)
            }
            clipURLs.append(url)

            let progress = Double(i + 1) / Double(sequence.count) * 0.50
            onProgress(0.02 + progress, "Clip \(i + 1)/\(sequence.count) ready")
        }

        defer {
            for url in clipURLs { try? FileManager.default.removeItem(at: url) }
        }

        onProgress(0.54, "Assembling composition…")

        // Step 2 — Build AVMutableComposition
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw RenderError.compositionFailed }

        var insertTime = CMTime.zero
        for (clipURL, item) in zip(clipURLs, sequence) {
            let clipAsset   = AVURLAsset(url: clipURL)
            let clipDuration = CMTime(seconds: item.duration, preferredTimescale: timescale)
            guard let srcTrack = try? await clipAsset.loadTracks(withMediaType: .video).first else {
                logger.error("No video track in exported clip for asset \(item.assetID) — inserting gap")
                insertTime = CMTimeAdd(insertTime, clipDuration)
                continue
            }
            let assetDur = (try? await clipAsset.load(.duration)) ?? clipDuration
            let range = CMTimeRange(start: .zero, duration: min(clipDuration, assetDur))
            do {
                try videoTrack.insertTimeRange(range, of: srcTrack, at: insertTime)
            } catch {
                logger.error("insertTimeRange failed for asset \(item.assetID): \(error)")
            }
            insertTime = CMTimeAdd(insertTime, min(clipDuration, assetDur))
        }

        let totalDuration = insertTime

        // Step 3 — Add audio from song
        let songAsset = AVURLAsset(url: songURL)
        if let songAudioTrack = try? await songAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let songDur = (try? await songAsset.load(.duration)) ?? totalDuration
            let audioDur = min(totalDuration, songDur)
            try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDur), of: songAudioTrack, at: .zero)
        }

        onProgress(0.60, "Rendering…")

        // Step 4 — Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemX_\(UUID().uuidString).mp4")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPreset1920x1080
        ) else { throw RenderError.exportSessionFailed }

        exportSession.shouldOptimizeForNetworkUse = true

        // Poll progress on a background Task
        let progressTask = Task {
            while !Task.isCancelled {
                onProgress(0.60 + Double(exportSession.progress) * 0.38, "Rendering… \(Int(exportSession.progress * 100))%")
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { progressTask.cancel() }

        try await exportSession.export(to: outputURL, as: .mp4)

        logger.info("Render complete: \(self.formatDuration(totalDuration.seconds)), output=\(outputURL.lastPathComponent)")
        onProgress(1.0, "Render complete — \(formatDuration(totalDuration.seconds))")
        return outputURL
    }

    // MARK: - Photo → Video Clip

    private func exportPhotoClip(assetID: String, duration: CMTime) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        let cgImage = await fetchCGImageFromPhotos(assetID: assetID)
            ?? createPlaceholderImage(assetID: assetID)
        guard let image = cgImage else { throw RenderError.assetNotFound(assetID) }

        let pixelBuffer = try createPixelBuffer(from: image)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input  = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RenderError.compositionFailed
        }
        writer.startSession(atSourceTime: .zero)

        // First frame at t=0
        adaptor.append(pixelBuffer, withPresentationTime: .zero)

        // Duplicate frame near end to establish duration
        let lastFrameTime = CMTimeSubtract(duration, CMTime(value: 1, timescale: CMTimeScale(fps)))
        let safeEnd = CMTimeCompare(lastFrameTime, .zero) > 0
            ? lastFrameTime
            : CMTime(value: 1, timescale: CMTimeScale(fps))
        adaptor.append(pixelBuffer, withPresentationTime: safeEnd)

        input.markAsFinished()

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? RenderError.compositionFailed
        }
        return outputURL
    }

    // MARK: - Video → Exported Clip

    private func exportVideoClip(assetID: String, startTime: TimeInterval, duration: TimeInterval) async throws -> URL {
        try await PhotosLibraryService.shared.exportVideoClip(assetID: assetID, startTime: startTime, duration: duration)
    }

    // MARK: - Pixel Buffer

    private func createPixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(renderSize.width), Int(renderSize.height),
            kCVPixelFormatType_32ARGB,
            attrs, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw RenderError.pixelBufferFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(renderSize.width), height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw RenderError.pixelBufferFailed }

        // Letterbox: black background, aspect-fit image centered
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Int(renderSize.width), height: Int(renderSize.height)))

        let iw = CGFloat(cgImage.width), ih = CGFloat(cgImage.height)
        let scale = min(renderSize.width / iw, renderSize.height / ih)
        let drawW = iw * scale, drawH = ih * scale
        let drawX = (renderSize.width - drawW) / 2
        let drawY = (renderSize.height - drawH) / 2
        ctx.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        return buffer
    }

    // MARK: - Image Helpers

    private func fetchCGImageFromPhotos(assetID: String) async -> CGImage? {
        let results = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let phAsset = results.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: Int(renderSize.width), height: Int(renderSize.height)),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private func createPlaceholderImage(assetID: String) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(renderSize.width), height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(renderSize.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        let hue = CGFloat(abs(assetID.hashValue % 1000)) / 1000.0
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.4, brightness: 0.25, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: Int(renderSize.width), height: Int(renderSize.height)))
        return ctx.makeImage()
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

// MARK: - RenderError

enum RenderError: LocalizedError {
    case emptySequence
    case assetNotFound(String)
    case compositionFailed
    case exportSessionFailed
    case exportFailed
    case pixelBufferFailed

    var errorDescription: String? {
        switch self {
        case .emptySequence:         return "No clips in the storyboard."
        case .assetNotFound(let id): return "Asset not found: \(id)"
        case .compositionFailed:     return "Failed to build video composition."
        case .exportSessionFailed:   return "Failed to create export session."
        case .exportFailed:          return "Video export failed."
        case .pixelBufferFailed:     return "Failed to create pixel buffer."
        }
    }
}
