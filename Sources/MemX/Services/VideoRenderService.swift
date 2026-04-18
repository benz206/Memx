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

    private let timescale: CMTimeScale = 600
    private let fps: Int32  = 30
    private let exportConcurrencyLimit = 3

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

        let renderSize = computeRenderSize(for: sequence, assetMap: assetMap, settings: plan.settings)
        let songVolume = Float(max(0, min(1, plan.settings.songVolume)))

        logger.info("Render started: \(sequence.count) clips, size=\(Int(renderSize.width))x\(Int(renderSize.height)), volume=\(Int(songVolume * 100))%, song=\(songURL.lastPathComponent)")
        onProgress(0.01, "Render size: \(Int(renderSize.width))×\(Int(renderSize.height)) · \(Int(songVolume * 100))% song volume")
        onProgress(0.02, "Exporting \(sequence.count) clips…")

        // Step 1 — Export clips concurrently (bounded at exportConcurrencyLimit)
        var clipURLs: [URL?] = [URL?](repeating: nil, count: sequence.count)

        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var inFlight = 0
            var nextIndex = 0

            while nextIndex < sequence.count || inFlight > 0 {
                while inFlight < exportConcurrencyLimit && nextIndex < sequence.count {
                    let i = nextIndex
                    let item = sequence[i]
                    group.addTask {
                        let url: URL
                        if let asset = assetMap[item.assetID], asset.isVideo {
                            do {
                                url = try await self.exportVideoClip(
                                    assetID: item.assetID, startTime: item.clipOffset, duration: item.duration)
                            } catch {
                                logger.warning("Video export failed for \(item.assetID), falling back to thumbnail: \(error)")
                                url = try await self.exportPhotoClip(
                                    assetID: item.assetID,
                                    duration: CMTime(seconds: item.duration, preferredTimescale: self.timescale),
                                    renderSize: renderSize)
                            }
                        } else {
                            url = try await self.exportPhotoClip(
                                assetID: item.assetID,
                                duration: CMTime(seconds: item.duration, preferredTimescale: self.timescale),
                                renderSize: renderSize)
                        }
                        return (i, url)
                    }
                    inFlight += 1
                    nextIndex += 1
                }

                let (i, url) = try await group.next()!
                clipURLs[i] = url
                inFlight -= 1
                let done = sequence.count - inFlight - max(0, sequence.count - nextIndex)
                let progress = Double(done) / Double(sequence.count) * 0.50
                onProgress(0.02 + progress, "Clip \(i + 1)/\(sequence.count) ready")
            }
        }

        let resolvedURLs = clipURLs.compactMap { $0 }

        defer {
            for url in resolvedURLs { try? FileManager.default.removeItem(at: url) }
        }

        onProgress(0.54, "Assembling composition (AVMutableComposition)…")

        // Step 2 — Build AVMutableComposition
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw RenderError.compositionFailed }

        struct Segment {
            let srcNaturalSize: CGSize
            let srcTransform: CGAffineTransform
            let compositionRange: CMTimeRange
        }
        var segments: [Segment] = []
        var insertTime = CMTime.zero

        for (clipURL, item) in zip(resolvedURLs, sequence) {
            let clipAsset   = AVURLAsset(url: clipURL)
            let clipDuration = CMTime(seconds: item.duration, preferredTimescale: timescale)
            guard let srcTrack = try? await clipAsset.loadTracks(withMediaType: .video).first else {
                logger.error("No video track in exported clip for asset \(item.assetID) — inserting gap")
                insertTime = CMTimeAdd(insertTime, clipDuration)
                continue
            }
            let assetDur = (try? await clipAsset.load(.duration)) ?? clipDuration
            let range = CMTimeRange(start: .zero, duration: min(clipDuration, assetDur))
            let clipStart = insertTime
            do {
                try videoTrack.insertTimeRange(range, of: srcTrack, at: insertTime)
            } catch {
                logger.error("insertTimeRange failed for asset \(item.assetID): \(error)")
                insertTime = CMTimeAdd(insertTime, range.duration)
                continue
            }
            let naturalSize = (try? await srcTrack.load(.naturalSize)) ?? renderSize
            let srcTransform = (try? await srcTrack.load(.preferredTransform)) ?? .identity
            segments.append(Segment(
                srcNaturalSize: naturalSize,
                srcTransform: srcTransform,
                compositionRange: CMTimeRange(start: clipStart, duration: range.duration)
            ))
            insertTime = CMTimeAdd(insertTime, range.duration)
        }

        let totalDuration = insertTime

        onProgress(0.56, "Attaching audio track (volume \(Int(songVolume * 100))%)…")

        // Step 3 — Add audio from song
        let songAsset = AVURLAsset(url: songURL)
        var audioMix: AVMutableAudioMix? = nil
        if let songAudioTrack = try? await songAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let songDur = (try? await songAsset.load(.duration)) ?? totalDuration
            let audioDur = min(totalDuration, songDur)
            try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDur), of: songAudioTrack, at: .zero)

            let mix = AVMutableAudioMix()
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(songVolume, at: .zero)
            mix.inputParameters = [params]
            audioMix = mix
        }

        onProgress(0.58, "Building video composition (\(Int(renderSize.width))×\(Int(renderSize.height)) @ \(fps)fps)…")

        // Build video composition with aspect-fit per-segment transforms
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for seg in segments {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = seg.compositionRange
            inst.backgroundColor = CGColor(gray: 0, alpha: 1)

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let t = aspectFitTransform(
                naturalSize: seg.srcNaturalSize,
                preferredTransform: seg.srcTransform,
                into: renderSize
            )
            layer.setTransform(t, at: seg.compositionRange.start)
            inst.layerInstructions = [layer]
            instructions.append(inst)
        }
        videoComposition.instructions = instructions

        onProgress(0.60, "Exporting via AVAssetExportSession…")

        // Step 4 — Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memx-\(UUID().uuidString).mp4")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw RenderError.exportSessionFailed }

        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = videoComposition
        exportSession.audioMix = audioMix

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

    // MARK: - Render Size Selection

    /// Picks a render canvas that preserves the majority orientation of the clips in the sequence.
    /// Phone footage is usually portrait or landscape — never letterbox a whole portrait montage
    /// into a 1920×1080 canvas.
    private func computeRenderSize(
        for sequence: [MontageSequenceItem],
        assetMap: [String: MediaAsset],
        settings: MontageSettings
    ) -> CGSize {
        var portraitCount = 0
        var landscapeCount = 0
        var squareCount = 0
        var maxPortraitSize = CGSize(width: 1080, height: 1920)
        var maxLandscapeSize = CGSize(width: 1920, height: 1080)

        for item in sequence {
            guard let asset = assetMap[item.assetID], asset.pixelWidth > 0, asset.pixelHeight > 0 else { continue }
            let w = asset.pixelWidth, h = asset.pixelHeight
            let ratio = Double(w) / Double(h)
            if ratio > 1.05 {
                landscapeCount += 1
                if w * h > Int(maxLandscapeSize.width * maxLandscapeSize.height) {
                    maxLandscapeSize = CGSize(width: w, height: h)
                }
            } else if ratio < 0.95 {
                portraitCount += 1
                if w * h > Int(maxPortraitSize.width * maxPortraitSize.height) {
                    maxPortraitSize = CGSize(width: w, height: h)
                }
            } else {
                squareCount += 1
            }
        }

        if portraitCount == 0 && landscapeCount == 0 && squareCount == 0 {
            switch settings.aspectRatio {
            case .portrait:   return CGSize(width: 1080, height: 1920)
            case .widescreen: return CGSize(width: 1920, height: 1080)
            case .square:     return CGSize(width: 1080, height: 1080)
            }
        }

        if portraitCount > landscapeCount && portraitCount >= squareCount {
            return cap(maxPortraitSize, longEdge: 1920)
        }
        if landscapeCount > portraitCount && landscapeCount >= squareCount {
            return cap(maxLandscapeSize, longEdge: 1920)
        }
        if squareCount > 0 && squareCount >= portraitCount && squareCount >= landscapeCount {
            return CGSize(width: 1080, height: 1080)
        }
        return cap(maxLandscapeSize, longEdge: 1920)
    }

    private func cap(_ size: CGSize, longEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > longEdge else { return evenSize(size) }
        let scale = longEdge / longest
        return evenSize(CGSize(width: size.width * scale, height: size.height * scale))
    }

    /// H.264 encoders require even dimensions.
    private func evenSize(_ size: CGSize) -> CGSize {
        let w = Int(size.width.rounded()); let h = Int(size.height.rounded())
        return CGSize(width: w - (w % 2), height: h - (h % 2))
    }

    /// Builds a transform that applies the source's preferred transform (to re-orient
    /// portrait phone footage correctly) and then aspect-fits the oriented frame into
    /// `renderSize`, centered on black. Preserves the user's original orientation.
    private func aspectFitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        into renderSize: CGSize
    ) -> CGAffineTransform {
        let transformed = naturalSize.applying(preferredTransform)
        let displayW = max(1, abs(transformed.width))
        let displayH = max(1, abs(transformed.height))

        let scale = min(renderSize.width / displayW, renderSize.height / displayH)
        let scaledW = displayW * scale
        let scaledH = displayH * scale
        let tx = (renderSize.width - scaledW) / 2
        let ty = (renderSize.height - scaledH) / 2

        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    // MARK: - Photo → Video Clip

    private func exportPhotoClip(assetID: String, duration: CMTime, renderSize: CGSize) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memx-\(UUID().uuidString).mp4")

        let cgImage = await fetchCGImageFromPhotos(assetID: assetID, renderSize: renderSize)
            ?? createPlaceholderImage(assetID: assetID, renderSize: renderSize)
        guard let image = cgImage else { throw RenderError.assetNotFound(assetID) }

        let pixelBuffer = try createPixelBuffer(from: image, renderSize: renderSize)

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

        adaptor.append(pixelBuffer, withPresentationTime: .zero)

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

    private func createPixelBuffer(from cgImage: CGImage, renderSize: CGSize) throws -> CVPixelBuffer {
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

    private func fetchCGImageFromPhotos(assetID: String, renderSize: CGSize) async -> CGImage? {
        guard let phAsset = await PHAssetCache.shared.phAsset(for: assetID) else { return nil }

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

    private func createPlaceholderImage(assetID: String, renderSize: CGSize) -> CGImage? {
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
