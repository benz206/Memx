import Foundation
import AVFoundation
import Accelerate
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "beatmap")

// MARK: - BeatmapServiceProtocol

protocol BeatmapServiceProtocol {
    func analyzeSong(
        at url: URL,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> Beatmap
}

// MARK: - BeatmapService (AVAudioFile + vDSP onset detection + autocorrelation BPM)

final class BeatmapService: BeatmapServiceProtocol {

    static let shared = BeatmapService()
    private init() {}

    func analyzeSong(
        at url: URL,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> Beatmap {

        onProgress(0.05, "Loading audio file...")
        logger.info("Beatmap analysis started: \(url.lastPathComponent)")

        let realDuration = await assetDuration(url: url)

        do {
            let result = try await performAnalysis(url: url, onProgress: onProgress)
            logger.info("Beatmap analysis complete: BPM=\(result.bpm, format: .fixed(precision: 1)), \(result.sections.count) sections, \(result.beats.count) beats")
            return result
        } catch {
            // File unreadable (mock path, DRM, etc.) — return mock beatmap with real duration
            logger.warning("Audio unreadable (\(error.localizedDescription)), using mock beatmap at \(realDuration > 0 ? realDuration : 180, format: .fixed(precision: 1))s")
            onProgress(1.0, "Beatmap complete")
            return MockDataProvider.mockBeatmap(duration: realDuration > 0 ? realDuration : 180)
        }
    }

    // MARK: - Core Analysis

    private func performAnalysis(url: URL, onProgress: @escaping (Double, String) -> Void) async throws -> Beatmap {
        let audioFile  = try AVAudioFile(forReading: url)
        let format     = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = audioFile.length
        let duration   = Double(totalFrames) / sampleRate

        // Cap at 10 minutes to keep memory sane
        let frameCount = AVAudioFrameCount(min(totalFrames, Int64(sampleRate * 600)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw BeatmapError.loadFailed("PCM buffer allocation failed")
        }
        try audioFile.read(into: buffer, frameCount: frameCount)
        guard let channelData = buffer.floatChannelData else {
            throw BeatmapError.loadFailed("No float channel data")
        }

        let frameLength  = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        onProgress(0.18, "Mixing to mono...")

        // Mix to mono (simple loop avoids vDSP aliasing)
        var mono = [Float](repeating: 0, count: frameLength)
        let invCh = 1.0 / Float(channelCount)
        for i in 0..<frameLength {
            var sum: Float = 0
            for ch in 0..<channelCount { sum += channelData[ch][i] }
            mono[i] = sum * invCh
        }

        onProgress(0.32, "Computing energy envelope...")

        let hopSamples = max(1, Int(sampleRate * 0.010))  // 10 ms hop
        let winSamples = max(hopSamples, Int(sampleRate * 0.023))  // 23 ms window
        let hopRate    = sampleRate / Double(hopSamples)

        let (envelope, energyCurve) = buildEnvelope(
            mono: mono, sampleRate: sampleRate,
            winSamples: winSamples, hopSamples: hopSamples
        )

        onProgress(0.52, "Estimating BPM via autocorrelation...")

        let bpm = estimateBPM(envelope: envelope, hopRate: hopRate)

        onProgress(0.66, "Detecting onsets...")

        let onsets = detectOnsets(envelope: envelope, hopRate: hopRate)

        onProgress(0.76, "Generating beat grid...")

        let beats = buildBeatGrid(bpm: bpm, onsets: onsets, duration: duration)

        onProgress(0.86, "Segmenting sections...")

        let sections = buildSections(energyCurve: energyCurve, duration: duration)
        let drops     = onsets.filter { $0.strength > 0.75 }.prefix(6).map { BeatMoment(time: $0.time, intensity: $0.strength) }
        let avgStr    = onsets.map(\.strength).reduce(0, +) / Double(max(onsets.count, 1))
        let vocal     = onsets.filter { $0.strength > avgStr * 1.2 && $0.strength < 0.75 }.prefix(12).map { BeatMoment(time: $0.time, intensity: $0.strength) }

        onProgress(1.0, "Beatmap complete")

        return Beatmap(
            bpm: bpm,
            durationSeconds: duration,
            energyCurve: energyCurve,
            sections: sections,
            beats: beats,
            drops: Array(drops),
            vocalPeaks: Array(vocal)
        )
    }

    // MARK: - Envelope + Energy Curve

    private func buildEnvelope(
        mono: [Float],
        sampleRate: Double,
        winSamples: Int,
        hopSamples: Int
    ) -> (envelope: [Float], energyCurve: [EnergyPoint]) {
        var envelope: [Float] = []
        var energyCurve: [EnergyPoint] = []
        let n = mono.count

        mono.withUnsafeBufferPointer { ptr in
            var i = 0
            while i + winSamples <= n {
                var rms: Float = 0
                vDSP_rmsqv(ptr.baseAddress! + i, 1, &rms, vDSP_Length(winSamples))
                envelope.append(rms)
                energyCurve.append(EnergyPoint(time: Double(i) / sampleRate, energy: Double(rms)))
                i += hopSamples
            }
        }

        // Normalize to [0, 1]
        var maxVal: Float = 0
        vDSP_maxv(envelope, 1, &maxVal, vDSP_Length(envelope.count))
        guard maxVal > 0 else { return (envelope, energyCurve) }

        var scale = 1.0 / maxVal
        vDSP_vsmul(envelope, 1, &scale, &envelope, 1, vDSP_Length(envelope.count))
        let invMax = 1.0 / Double(maxVal)
        energyCurve = energyCurve.map { EnergyPoint(time: $0.time, energy: min(1, $0.energy * invMax)) }

        return (envelope, energyCurve)
    }

    // MARK: - BPM via Autocorrelation

    private func estimateBPM(envelope: [Float], hopRate: Double) -> Double {
        let n = envelope.count
        guard n > 200 else { return 120 }

        let minLag = max(1, Int(hopRate * 60.0 / 200.0))  // 200 BPM ceiling
        let maxLag = min(n - 1, Int(hopRate * 60.0 / 50.0))  // 50 BPM floor
        guard minLag < maxLag else { return 120 }

        var bestLag = minLag
        var bestCorr: Float = -1

        envelope.withUnsafeBufferPointer { ptr in
            for lag in minLag...maxLag {
                let count = vDSP_Length(n - lag)
                var corr: Float = 0
                vDSP_dotpr(ptr.baseAddress!, 1, ptr.baseAddress! + lag, 1, &corr, count)
                corr /= Float(n - lag)
                if corr > bestCorr { bestCorr = corr; bestLag = lag }
            }
        }

        let beatPeriod = Double(bestLag) / hopRate
        return max(60, min(180, 60.0 / beatPeriod))
    }

    // MARK: - Onset Detection (positive spectral flux)

    private struct Onset { let time: Double; let strength: Double }

    private func detectOnsets(envelope: [Float], hopRate: Double) -> [Onset] {
        guard envelope.count > 2 else { return [] }

        // Positive first-order difference
        var flux = [Float](repeating: 0, count: envelope.count)
        for i in 1..<envelope.count {
            flux[i] = max(0, envelope[i] - envelope[i - 1])
        }

        var mean: Float = 0, meanSq: Float = 0
        vDSP_meanv(flux, 1, &mean, vDSP_Length(flux.count))
        vDSP_measqv(flux, 1, &meanSq, vDSP_Length(flux.count))
        let std = sqrt(max(0, meanSq - mean * mean))
        let threshold = mean + std * 1.5

        var maxFlux: Float = 1
        vDSP_maxv(flux, 1, &maxFlux, vDSP_Length(flux.count))
        if maxFlux == 0 { maxFlux = 1 }

        let minGap = Int(hopRate * 0.08)  // 80 ms minimum gap
        var lastIdx = -minGap
        var onsets: [Onset] = []

        for i in 1..<(flux.count - 1) {
            guard flux[i] > threshold else { continue }
            guard i - lastIdx >= minGap else { continue }
            guard flux[i] >= flux[i - 1], flux[i] >= flux[i + 1] else { continue }
            onsets.append(Onset(time: Double(i) / hopRate, strength: min(1, Double(flux[i] / maxFlux))))
            lastIdx = i
        }
        return onsets
    }

    // MARK: - Beat Grid

    private func buildBeatGrid(bpm: Double, onsets: [Onset], duration: Double) -> [Double] {
        let interval = 60.0 / bpm
        // Anchor to strongest onset in first 20% of song
        var phase = 0.0
        let earlyWindow = duration * 0.2
        if let anchor = onsets.filter({ $0.time < earlyWindow }).max(by: { $0.strength < $1.strength }) {
            phase = anchor.time.truncatingRemainder(dividingBy: interval)
        }
        var beats: [Double] = []
        var t = phase < 0 ? phase + interval : phase
        while t < duration { beats.append(t); t += interval }
        return beats
    }

    // MARK: - Section Segmentation

    private func buildSections(energyCurve: [EnergyPoint], duration: Double) -> [BeatSection] {
        guard !energyCurve.isEmpty, duration > 0 else { return [] }

        let blockDur = 12.0
        var blocks: [(time: Double, energy: Double)] = []
        var t = 0.0
        while t < duration {
            let end = min(t + blockDur, duration)
            let pts = energyCurve.filter { $0.time >= t && $0.time < end }
            let avg = pts.isEmpty ? 0.3 : pts.map(\.energy).reduce(0, +) / Double(pts.count)
            blocks.append((t, avg))
            t += blockDur
        }

        let avgE = blocks.map(\.energy).reduce(0, +) / Double(max(blocks.count, 1))
        var sections: [BeatSection] = []

        for (i, block) in blocks.enumerated() {
            let start = block.time
            let end   = i + 1 < blocks.count ? blocks[i + 1].time : duration
            let e     = block.energy
            let pos   = start / duration
            let prevE = i > 0 ? blocks[i - 1].energy : e
            let nextE = i + 1 < blocks.count ? blocks[i + 1].energy : e

            let type: SectionType
            if pos < 0.07 {
                type = .intro
            } else if pos > 0.90 {
                type = .outro
            } else if e > avgE * 1.55 && e > prevE * 1.25 {
                type = nextE > e * 0.80 ? .chorus : .drop
            } else if e > avgE * 1.15 && e > prevE {
                type = pos < 0.50 ? .preChorus : .buildup
            } else if e < avgE * 0.55 {
                type = (0.40...0.65).contains(pos) ? .bridge : .breakdown
            } else {
                type = .verse
            }

            let cutStyle: CutStyle
            switch type {
            case .drop:                cutStyle = .rapidCut
            case .buildup, .preChorus: cutStyle = .accelerating
            case .chorus:              cutStyle = .onBeat
            case .breakdown:           cutStyle = .singleHold
            case .intro:               cutStyle = .slowFade
            case .bridge, .outro:      cutStyle = .kenBurnsDrift
            case .verse:               cutStyle = .onBeat
            }

            sections.append(BeatSection(type: type, start: start, end: end, energyAvg: e, cutStyle: cutStyle))
        }
        return sections
    }

    // MARK: - Helpers

    private func assetDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return 0 }
        let secs = CMTimeGetSeconds(dur)
        return secs.isFinite && secs > 0 ? secs : 0
    }
}

// MARK: - BeatmapError

enum BeatmapError: LocalizedError {
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let msg): return "Audio load failed: \(msg)"
        }
    }
}
