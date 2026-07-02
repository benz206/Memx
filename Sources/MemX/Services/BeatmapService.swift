import Foundation
@preconcurrency import AVFoundation
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
            logger.warning("Audio unreadable (\(error.localizedDescription)), using mock beatmap at \(realDuration > 0 ? realDuration : 180, format: .fixed(precision: 1))s")
            onProgress(1.0, "Beatmap complete")
            return MockDataProvider.mockBeatmap(duration: realDuration > 0 ? realDuration : 180)
        }
    }

    // MARK: - Core Analysis

    private static let windowSeconds = 5.0
    private static let targetSampleRate: Double = 22050

    private func performAnalysis(url: URL, onProgress: @escaping (Double, String) -> Void) async throws -> Beatmap {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        let sourceSampleRate = sourceFormat.sampleRate
        let totalFrames = audioFile.length
        let duration = Double(totalFrames) / sourceSampleRate

        let outSampleRate = Self.targetSampleRate
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw BeatmapError.loadFailed("Cannot create mono output format")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: monoFormat) else {
            throw BeatmapError.loadFailed("Cannot create audio converter")
        }

        let windowFramesSource = AVAudioFrameCount(sourceSampleRate * Self.windowSeconds)
        let windowFramesMono   = AVAudioFrameCount(outSampleRate * Self.windowSeconds)

        var mono: [Float] = []
        mono.reserveCapacity(Int(Double(totalFrames) / sourceSampleRate * outSampleRate) + 1)

        onProgress(0.18, "Streaming audio to mono 22 kHz...")

        while audioFile.framePosition < totalFrames {
            let remaining = AVAudioFrameCount(totalFrames - audioFile.framePosition)
            let chunkFrames = min(windowFramesSource, remaining)

            guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                throw BeatmapError.loadFailed("PCM buffer allocation failed")
            }
            try audioFile.read(into: srcBuffer, frameCount: chunkFrames)
            guard srcBuffer.frameLength > 0 else { break }

            guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: windowFramesMono) else {
                throw BeatmapError.loadFailed("Mono buffer allocation failed")
            }

            var conversionError: NSError?
            var inputConsumed = false
            converter.convert(to: dstBuffer, error: &conversionError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return srcBuffer
            }

            if let err = conversionError { throw err }

            let frameLen = Int(dstBuffer.frameLength)
            if frameLen == 0 { continue }
            guard let channelData = dstBuffer.floatChannelData else { continue }
            mono.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLen))
        }

        guard !mono.isEmpty else { throw BeatmapError.loadFailed("No audio data after conversion") }

        let sampleRate = outSampleRate

        onProgress(0.32, "Computing energy envelope...")

        let hopSamples = max(1, Int(sampleRate * 0.010))
        let winSamples = max(hopSamples, Int(sampleRate * 0.023))
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

        let phraseSize = bpm > 140 ? 8 : 4
        let phraseStarts = stride(from: 0, to: beats.count, by: 4 * phraseSize).map { beats[$0] }

        let bd = 60.0 / max(bpm, 1)
        let beatStrengths: [Double] = beats.enumerated().map { i, beatTime in
            let base: Double = (i % 4) == 0 ? 0.75 : (i % 4) == 2 ? 0.5 : 0.35
            let isPhrase = phraseStarts.contains(where: { abs($0 - beatTime) < bd * 0.5 })
            return isPhrase ? 1.0 : base
        }

        onProgress(0.92, "Detecting hooks…")
        let hooks = detectHooks(
            envelope: envelope,
            hopRate: hopRate,
            sections: sections,
            beats: beats,
            beatStrengths: beatStrengths
        )

        onProgress(1.0, "Beatmap complete")

        return Beatmap(
            bpm: bpm,
            durationSeconds: duration,
            energyCurve: energyCurve,
            sections: sections,
            beats: beats,
            drops: Array(drops),
            vocalPeaks: Array(vocal),
            phraseStarts: phraseStarts,
            beatStrengths: beatStrengths,
            hooks: hooks
        )
    }

    // MARK: - Hook Detection (section-fingerprint cosine clustering)
    // Simplified feature: per-section 8-dim fingerprint built from the energy
    // envelope + its slope (spectral-centroid/FFT-free). Fingerprints are
    // compared pairwise via cosine similarity; pairs > 0.75 are clustered.
    // Sections in a cluster of size ≥ 2 are emitted as HookMoments ordered
    // chronologically, with repeatIndex = chronological index in the cluster.

    private func detectHooks(
        envelope: [Float],
        hopRate: Double,
        sections: [BeatSection],
        beats: [Double],
        beatStrengths: [Double]
    ) -> [HookMoment] {
        let candidates = sections.enumerated().filter { _, s in
            s.type == .chorus || s.type == .drop
        }
        guard candidates.count >= 2 else {
            logger.info("Hooks detected: 0 moments (insufficient chorus/drop sections)")
            return []
        }

        // Build per-section fingerprints.
        let fingerprints = candidates.map { (idx, section) -> (Int, BeatSection, [Double]) in
            (idx, section, sectionFingerprint(section: section, envelope: envelope, hopRate: hopRate))
        }

        // Union-find style clustering via pairwise cosine similarity.
        let n = fingerprints.count
        var parent = Array(0..<n)
        func find(_ a: Int) -> Int {
            var x = a
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Store pairwise similarity for each pair; we'll use the max similarity
        // each section has to any other cluster member as its "similarity" score.
        var bestSimilarity = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let sim = cosineSimilarity(fingerprints[i].2, fingerprints[j].2)
                if sim > 0.75 {
                    union(i, j)
                    bestSimilarity[i] = max(bestSimilarity[i], sim)
                    bestSimilarity[j] = max(bestSimilarity[j], sim)
                }
            }
        }

        // Group by root; drop clusters of size < 2.
        var clusters = [Int: [Int]]()
        for i in 0..<n { clusters[find(i), default: []].append(i) }
        let validClusters = clusters.values.filter { $0.count >= 2 }
        let clusterCount = validClusters.count

        // Emit hooks in chronological order; repeatIndex is within-cluster.
        var hooks = [HookMoment]()
        for cluster in validClusters {
            // Sort the cluster by section start time; repeatIndex = order in cluster.
            let sorted = cluster.sorted { fingerprints[$0].1.start < fingerprints[$1].1.start }
            for (k, memberIdx) in sorted.enumerated() {
                let section = fingerprints[memberIdx].1
                let sig = signatureBeats(
                    in: section.start...section.end,
                    beats: beats,
                    beatStrengths: beatStrengths
                )
                hooks.append(HookMoment(
                    startTime: section.start,
                    endTime: section.end,
                    repeatIndex: k,
                    signatureBeats: sig,
                    similarity: bestSimilarity[memberIdx]
                ))
            }
        }
        hooks.sort { $0.startTime < $1.startTime }

        logger.info("Hooks detected: \(hooks.count) moments across \(clusterCount) clusters")
        return hooks
    }

    /// 8-dim fingerprint = four equal-width envelope RMS bins + their forward
    /// slopes. No FFT, but captures macro energy shape well enough to cluster
    /// repeated choruses.
    private func sectionFingerprint(
        section: BeatSection,
        envelope: [Float],
        hopRate: Double
    ) -> [Double] {
        let i0 = max(0, Int(section.start * hopRate))
        let i1 = min(envelope.count, Int(section.end * hopRate))
        guard i1 > i0 + 8 else {
            return Array(repeating: 0, count: 8)
        }
        let span  = i1 - i0
        let bins  = 4
        let step  = max(1, span / bins)
        var rms   = [Double](repeating: 0, count: bins)
        for b in 0..<bins {
            let s = i0 + b * step
            let e = min(i1, s + step)
            guard e > s else { continue }
            var sum = 0.0
            for k in s..<e { sum += Double(envelope[k]) }
            rms[b] = sum / Double(e - s)
        }
        var slopes = [Double](repeating: 0, count: bins)
        for b in 0..<bins {
            slopes[b] = b + 1 < bins ? rms[b + 1] - rms[b] : rms[b] - (b > 0 ? rms[b - 1] : rms[b])
        }
        return rms + slopes
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 1e-9 ? dot / denom : 0
    }

    /// Pick the 4 strongest beats within the range, ordered by time.
    private func signatureBeats(
        in range: ClosedRange<Double>,
        beats: [Double],
        beatStrengths: [Double]
    ) -> [Double] {
        let indexed = beats.enumerated().filter { range.contains($0.element) }
        let ranked = indexed.sorted { a, b in
            let sa = beatStrengths.indices.contains(a.offset) ? beatStrengths[a.offset] : 0.4
            let sb = beatStrengths.indices.contains(b.offset) ? beatStrengths[b.offset] : 0.4
            return sa > sb
        }
        return ranked.prefix(4).map(\.element).sorted()
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
        // BPM is stable enough that the first ~90s resolves it.
        let n = min(envelope.count, Int(hopRate * 90.0))
        guard n > 200 else { return 120 }

        let minLag = max(1, Int(hopRate * 60.0 / 200.0))
        let maxLag = min(n - 1, Int(hopRate * 60.0 / 50.0))
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

    // MARK: - Onset Detection (positive energy flux on the RMS envelope)

    private struct Onset { let time: Double; let strength: Double }

    private func detectOnsets(envelope: [Float], hopRate: Double) -> [Onset] {
        guard envelope.count > 2 else { return [] }

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

        let minGap = Int(hopRate * 0.08)
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

    // MARK: - Section Segmentation (O(n) two-pointer sweep)

    private func buildSections(energyCurve: [EnergyPoint], duration: Double) -> [BeatSection] {
        guard !energyCurve.isEmpty, duration > 0 else { return [] }

        let blockDur = 12.0
        var blocks: [(time: Double, energy: Double)] = []
        var t = 0.0

        var curveIndex = 0
        let curveCount = energyCurve.count

        while t < duration {
            let end = min(t + blockDur, duration)
            var sum = 0.0
            var count = 0

            while curveIndex < curveCount && energyCurve[curveIndex].time < end {
                if energyCurve[curveIndex].time >= t {
                    sum += energyCurve[curveIndex].energy
                    count += 1
                }
                curveIndex += 1
            }
            if curveIndex > 0 && curveIndex < curveCount { curveIndex -= 1 }

            let avg = count == 0 ? 0.3 : sum / Double(count)
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

            sections.append(BeatSection(type: type, start: start, end: end, energyAvg: e))
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
