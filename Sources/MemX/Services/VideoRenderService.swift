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
        beatmap: Beatmap?,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> URL
}

// MARK: - VideoRenderService (AVMutableComposition + AVAssetExportSession)
// Two alternating video tracks (A/B) so adjacent clips can overlap. Every
// clip is placed at its *plan* startTime — the song timeline — so cuts stay
// locked to the beatgrid even if an export comes back short or a slot was
// skipped. Transitions from the storyboard are rendered for real: crossfade /
// dissolve opacity ramps, flash-white dips, whip-pan pushes, fade-from-black,
// plus Ken Burns drift and beat punch-ins on photos via transform ramps.

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
        beatmap: Beatmap?,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let sequence = plan.sequence
        guard !sequence.isEmpty else { throw RenderError.emptySequence }

        // Beat-synced brightness pulses (no beatmap → identity envelope).
        let pulseEnvelope = RenderTimeline.PulseEnvelope(
            pulses: beatmap.map { RenderTimeline.beatPulses(beatmap: $0) } ?? [])

        let renderSize = computeRenderSize(for: sequence, assetMap: assetMap, settings: plan.settings)
        let songVolume = Float(max(0, min(1, plan.settings.songVolume)))
        let segmentPlans = RenderTimeline.plan(sequence, beatDuration: beatmap?.beatDuration)

        logger.info("Render started: \(sequence.count) clips, size=\(Int(renderSize.width))x\(Int(renderSize.height)), volume=\(Int(songVolume * 100))%, song=\(songURL.lastPathComponent)")
        onProgress(0.01, "Render size: \(Int(renderSize.width))×\(Int(renderSize.height)) · \(Int(songVolume * 100))% song volume")
        onProgress(0.02, "Exporting \(sequence.count) clips…")

        // Step 1 — Export clips concurrently (bounded at exportConcurrencyLimit).
        // Each clip is exported long enough to cover its visible window plus
        // the outgoing tail it holds under the next clip's transition.
        var clipURLs: [URL?] = [URL?](repeating: nil, count: sequence.count)

        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var inFlight = 0
            var nextIndex = 0

            while nextIndex < sequence.count || inFlight > 0 {
                while inFlight < exportConcurrencyLimit && nextIndex < sequence.count {
                    let i = nextIndex
                    let item = sequence[i]
                    let neededDuration = segmentPlans[i].sourceDuration
                    group.addTask {
                        let url: URL
                        if let asset = assetMap[item.assetID], asset.isVideo {
                            do {
                                url = try await self.exportVideoClip(
                                    assetID: item.assetID,
                                    startTime: item.clipOffset,
                                    duration: neededDuration + 0.15)
                            } catch {
                                logger.warning("Video export failed for \(item.assetID), falling back to thumbnail: \(error)")
                                url = try await self.exportPhotoClip(
                                    assetID: item.assetID,
                                    duration: CMTime(seconds: neededDuration, preferredTimescale: self.timescale),
                                    renderSize: renderSize)
                            }
                        } else {
                            url = try await self.exportPhotoClip(
                                assetID: item.assetID,
                                duration: CMTime(seconds: neededDuration, preferredTimescale: self.timescale),
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

        defer {
            for url in clipURLs.compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        }

        onProgress(0.54, "Assembling composition (A/B transition tracks)…")

        // Step 2 — Build AVMutableComposition with two alternating video tracks.
        let composition = AVMutableComposition()
        var videoTracks = [AVMutableCompositionTrack]()
        for _ in 0..<2 {
            guard let t = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw RenderError.compositionFailed }
            videoTracks.append(t)
        }
        var trackCursors = [CMTime](repeating: .zero, count: videoTracks.count)

        struct PlacedSegment {
            let plan: RenderSegmentPlan
            let item: MontageSequenceItem
            let track: AVMutableCompositionTrack
            let baseTransform: CGAffineTransform
            let motion: SegmentMotion?
            let insertedEnd: Double     // start + actually inserted media duration

            var effectiveVisibleEnd: Double { min(plan.visibleEnd, insertedEnd) }
            var effectivePresenceEnd: Double { min(plan.presenceEnd, insertedEnd) }
        }
        var placed = [PlacedSegment]()

        for (i, segPlan) in segmentPlans.enumerated() {
            guard let clipURL = clipURLs[i] else { continue }
            let item = sequence[i]
            let clipAsset = AVURLAsset(url: clipURL)
            guard let srcTrack = try? await clipAsset.loadTracks(withMediaType: .video).first else {
                logger.error("No video track in exported clip for asset \(item.assetID) — skipping segment")
                continue
            }
            let neededDuration = CMTime(seconds: segPlan.sourceDuration, preferredTimescale: timescale)
            let assetDur = (try? await clipAsset.load(.duration)) ?? neededDuration
            let range = CMTimeRange(start: .zero, duration: min(neededDuration, assetDur))
            guard range.duration.seconds > 0.02 else { continue }

            let trackIdx = i % videoTracks.count
            let track = videoTracks[trackIdx]
            let targetStart = CMTime(seconds: segPlan.start, preferredTimescale: timescale)

            // Pad the track up to the segment's start so the media lands at
            // its exact song-timeline position (beat lock).
            if CMTimeCompare(trackCursors[trackIdx], targetStart) < 0 {
                track.insertEmptyTimeRange(CMTimeRange(start: trackCursors[trackIdx], end: targetStart))
            }
            do {
                try track.insertTimeRange(range, of: srcTrack, at: targetStart)
            } catch {
                logger.error("insertTimeRange failed for asset \(item.assetID): \(error)")
                continue
            }
            trackCursors[trackIdx] = CMTimeAdd(targetStart, range.duration)

            let naturalSize = (try? await srcTrack.load(.naturalSize)) ?? renderSize
            let srcTransform = (try? await srcTrack.load(.preferredTransform)) ?? .identity
            let isPhoto = !(assetMap[item.assetID]?.isVideo ?? false)

            placed.append(PlacedSegment(
                plan: segPlan,
                item: item,
                track: track,
                baseTransform: aspectFitTransform(
                    naturalSize: naturalSize,
                    preferredTransform: srcTransform,
                    into: renderSize),
                motion: RenderTimeline.motion(for: item, isPhoto: isPhoto,
                                              headTransition: segPlan.headTransition),
                insertedEnd: segPlan.start + range.duration.seconds
            ))
        }

        guard !placed.isEmpty else { throw RenderError.compositionFailed }
        let totalEnd = placed.map(\.effectivePresenceEnd).max() ?? 0
        let totalDuration = CMTime(seconds: totalEnd, preferredTimescale: timescale)

        onProgress(0.56, "Attaching audio track (volume \(Int(songVolume * 100))%)…")

        // Step 3 — Add audio from song, with a gentle fade-out at the end.
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
            let fadeLen = min(1.2, audioDur.seconds * 0.2)
            if fadeLen > 0.1 {
                let fadeStart = CMTime(seconds: audioDur.seconds - fadeLen, preferredTimescale: timescale)
                params.setVolumeRamp(fromStartVolume: songVolume, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: fadeStart, duration: CMTime(seconds: fadeLen, preferredTimescale: timescale)))
            }
            mix.inputParameters = [params]
            audioMix = mix
        }

        onProgress(0.58, "Building transitions (\(Int(renderSize.width))×\(Int(renderSize.height)) @ \(fps)fps)…")

        // Step 4 — Instruction timeline. Split at every segment knot so each
        // interval has a constant layer set, then emit exact opacity /
        // transform ramps per interval.
        let epsilon = 1e-3
        var knots: Set<Int> = [0]  // milliseconds for stable dedupe
        func addKnot(_ t: Double) { knots.insert(Int((t * 1000).rounded())) }
        for seg in placed {
            addKnot(seg.plan.start)
            if seg.plan.headOverlap > 0 {
                addKnot(seg.plan.start + seg.plan.headOverlap)
                // Interior knots so eased opacity/whip curves survive
                // AVFoundation's linear ramp interpolation.
                for f in RenderTimeline.easedKnotFractions {
                    addKnot(seg.plan.start + seg.plan.headOverlap * f)
                }
            }
            if seg.plan.headTransition == .fadeFromBlack {
                let d = RenderTimeline.fadeFromBlackDuration(seg.plan)
                addKnot(seg.plan.start + d)
                for f in RenderTimeline.easedKnotFractions {
                    addKnot(seg.plan.start + d * f)
                }
            }
            if let m = seg.motion, m.punchDuration > 0 { addKnot(seg.plan.start + m.punchDuration) }
            addKnot(seg.effectiveVisibleEnd)
            addKnot(seg.effectivePresenceEnd)
        }
        addKnot(totalEnd)

        // Instruction boundaries must tile [0, composition duration] exactly —
        // AVFoundation rejects any gap, overlap, or zero-length range with
        // AVErrorInvalidVideoComposition ("Operation Stopped"). Integer
        // millisecond CMTimes keep consecutive knots from collapsing when
        // rounded, and the final boundary is the composition's own duration so
        // the tail is always covered.
        let compositionEnd = try await composition.load(.duration)
        var boundaries = knots.sorted()
            .map { CMTime(value: CMTimeValue($0), timescale: 1000) }
            .filter { $0 < compositionEnd }
        boundaries.append(compositionEnd)

        func opacity(for seg: PlacedSegment, at t: Double) -> Float {
            Float(RenderTimeline.transitionOpacity(for: seg.plan, at: t))
        }

        func transform(for seg: PlacedSegment, at t: Double) -> CGAffineTransform {
            var result = seg.baseTransform
            let p = seg.plan
            if let m = seg.motion {
                let s = m.scale(atRelative: t - p.start, duration: p.sourceDuration)
                if abs(s - 1) > 0.0005 || m.panDX != 0 || m.panDY != 0 {
                    let cx = renderSize.width / 2, cy = renderSize.height / 2
                    let px = CGFloat(m.panDX * (s - 1) * 0.25) * renderSize.width
                    let py = CGFloat(m.panDY * (s - 1) * 0.25) * renderSize.height
                    let zoom = CGAffineTransform(translationX: cx + px, y: cy + py)
                        .scaledBy(x: CGFloat(s), y: CGFloat(s))
                        .translatedBy(x: -cx, y: -cy)
                    result = result.concatenating(zoom)
                }
            }
            if p.headTransition == .whipPan, p.headOverlap > 0, t < p.start + p.headOverlap {
                let g = RenderTimeline.whipProgress((t - p.start) / p.headOverlap)
                let dir = RenderTimeline.whipDirection(boundaryIndex: p.index)
                result = result.concatenating(
                    CGAffineTransform(translationX: CGFloat(dir) * renderSize.width * CGFloat(1 - g), y: 0))
            }
            if p.tailTransition == .whipPan, p.tailOverlap > 0, t > p.visibleEnd {
                let g = RenderTimeline.whipProgress((t - p.visibleEnd) / p.tailOverlap)
                let dir = RenderTimeline.whipDirection(boundaryIndex: p.index + 1)
                result = result.concatenating(
                    CGAffineTransform(translationX: CGFloat(-dir) * renderSize.width * CGFloat(g), y: 0))
            }
            return result
        }

        var instructions: [AVVideoCompositionInstruction] = []
        for ti in 0..<max(0, boundaries.count - 1) {
            let intervalRange = CMTimeRange(start: boundaries[ti], end: boundaries[ti + 1])
            let t0 = intervalRange.start.seconds, t1 = intervalRange.end.seconds
            let mid = (t0 + t1) / 2

            let active = placed
                .filter { $0.plan.start - epsilon <= mid && mid < $0.effectivePresenceEnd - 0 }
                .sorted { $0.plan.start > $1.plan.start }   // newest first = top layer

            // Flash-white boundaries dip through a white background.
            let flashActive = active.contains {
                $0.plan.headTransition == .flashWhite
                    && mid >= $0.plan.start - epsilon
                    && mid <= $0.plan.start + $0.plan.headOverlap + epsilon
            }

            // Beat-pulse bend points inside this interval, shared by every
            // active layer. Interior CMTimes stay on the same 1000-timescale
            // grid as the boundaries so sub-ramps tile the instruction range.
            var sampleTimes: [(time: CMTime, seconds: Double)] = [(intervalRange.start, t0)]
            for s in pulseEnvelope.knotTimes(in: t0, t1, minSpacing: 1.5 / Double(fps)) {
                sampleTimes.append((CMTime(value: CMTimeValue((s * 1000).rounded()), timescale: 1000), s))
            }
            sampleTimes.append((intervalRange.end, t1))

            var layers = [AVVideoCompositionLayerInstruction]()
            for seg in active {
                var config = AVVideoCompositionLayerInstruction.Configuration(assetTrack: seg.track)

                // The pulse multiplies into every active layer so a dip never
                // reveals an un-dimmed clip underneath; consecutive sub-ramps
                // starting at discontinuous values express the on-beat snap.
                for k in 0..<(sampleTimes.count - 1) {
                    let (c0, s0) = sampleTimes[k]
                    let (c1, s1) = sampleTimes[k + 1]
                    let o0 = Float(Double(opacity(for: seg, at: s0)) * pulseEnvelope.value(atOrAfter: s0))
                    let o1 = Float(Double(opacity(for: seg, at: s1)) * pulseEnvelope.value(before: s1))
                    if abs(o0 - o1) < 0.001 {
                        config.setOpacity(o0, at: c0)
                    } else {
                        config.addOpacityRamp(.init(timeRange: CMTimeRange(start: c0, end: c1), start: o0, end: o1))
                    }
                }

                let tr0 = transform(for: seg, at: t0)
                let tr1 = transform(for: seg, at: t1)
                if transformsEqual(tr0, tr1) {
                    config.setTransform(tr0, at: intervalRange.start)
                } else {
                    config.addTransformRamp(.init(timeRange: intervalRange, start: tr0, end: tr1))
                }
                layers.append(AVVideoCompositionLayerInstruction(configuration: config))
            }

            // backgroundColor must be an RGB color — AVFoundation doesn't
            // accept grayscale-colorspace CGColors here. Outside flashes it
            // is the dark section tint revealed by beat-pulse dips and
            // transition gaps, so hue only moves at section boundaries.
            let tint = RenderTimeline.sectionTint(
                active.first?.item.sectionType,
                hint: active.first?.item.gradingHint
            )
            let instConfig = AVVideoCompositionInstruction.Configuration(
                backgroundColor: flashActive
                    ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                    : CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: 1),
                layerInstructions: layers,
                timeRange: intervalRange
            )
            instructions.append(AVVideoCompositionInstruction(configuration: instConfig))
        }

        var videoCompositionConfig = AVVideoComposition.Configuration()
        videoCompositionConfig.renderSize = renderSize
        videoCompositionConfig.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoCompositionConfig.instructions = instructions
        let videoComposition = AVVideoComposition(configuration: videoCompositionConfig)

        onProgress(0.60, "Exporting via AVAssetExportSession…")

        // Step 5 — Export
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

        do {
            try await exportSession.export(to: outputURL, as: .mp4)
        } catch {
            let ns = error as NSError
            logger.error("Export failed: \(ns.domain) \(ns.code) — \(ns.localizedDescription); reason=\(ns.localizedFailureReason ?? "none"); userInfo=\(ns.userInfo)")
            let reason = ns.localizedFailureReason.map { " — \($0)" } ?? ""
            throw RenderError.exportFailed("\(ns.localizedDescription)\(reason) (\(ns.domain) \(ns.code))")
        }

        logger.info("Render complete: \(self.formatDuration(totalEnd)), output=\(outputURL.lastPathComponent)")
        onProgress(1.0, "Render complete — \(formatDuration(totalEnd))")
        return outputURL
    }

    // MARK: - Transition Helpers

    private func transformsEqual(_ a: CGAffineTransform, _ b: CGAffineTransform) -> Bool {
        abs(a.a - b.a) < 1e-5 && abs(a.b - b.b) < 1e-5
            && abs(a.c - b.c) < 1e-5 && abs(a.d - b.d) < 1e-5
            && abs(a.tx - b.tx) < 0.01 && abs(a.ty - b.ty) < 0.01
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
    // Static two-frame clip; all motion (Ken Burns, punch-ins) is applied via
    // transform ramps in the composition, so the compositor interpolates it
    // per output frame at zero export cost. Exported ~20% above render size
    // so zoom-ins never go soft.

    private func exportPhotoClip(
        assetID: String,
        duration: CMTime,
        renderSize: CGSize
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memx-\(UUID().uuidString).mp4")

        let clipSize = evenSize(CGSize(width: renderSize.width * 1.2, height: renderSize.height * 1.2))

        let cgImage = await fetchCGImageFromPhotos(assetID: assetID, renderSize: clipSize)
            ?? createPlaceholderImage(assetID: assetID, renderSize: clipSize)
        guard let image = cgImage else { throw RenderError.assetNotFound(assetID) }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(clipSize.width),
            AVVideoHeightKey: Int(clipSize.height),
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input  = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(clipSize.width),
                kCVPixelBufferHeightKey as String: Int(clipSize.height),
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RenderError.compositionFailed
        }
        writer.startSession(atSourceTime: .zero)

        let pixelBuffer = try createPixelBuffer(from: image, renderSize: clipSize)

        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        adaptor.append(pixelBuffer, withPresentationTime: .zero)

        let frameStep = CMTime(value: 1, timescale: CMTimeScale(fps))
        let endTime = CMTimeCompare(duration, frameStep) > 0
            ? CMTimeSubtract(duration, frameStep)
            : frameStep

        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        adaptor.append(pixelBuffer, withPresentationTime: endTime)

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
    case exportFailed(String)
    case pixelBufferFailed

    var errorDescription: String? {
        switch self {
        case .emptySequence:         return "No clips in the storyboard."
        case .assetNotFound(let id): return "Asset not found: \(id)"
        case .compositionFailed:     return "Failed to build video composition."
        case .exportSessionFailed:   return "Failed to create export session."
        case .exportFailed(let detail): return "Video export failed: \(detail)"
        case .pixelBufferFailed:     return "Failed to create pixel buffer."
        }
    }
}
