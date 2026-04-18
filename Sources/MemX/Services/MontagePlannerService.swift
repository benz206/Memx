import Foundation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "sequencer")

// MARK: - SequencerServiceProtocol

protocol SequencerServiceProtocol {
    func buildSequence(
        title: String,
        settings: MontageSettings,
        assets: [MediaAsset],
        motionPrompts: [MotionPrompt],
        beatmap: Beatmap,
        onProgress: @escaping (Double, String) -> Void
    ) async -> MontagePlan
}

// MARK: - SequencerService
//
// Cut rhythm rules:
//   Intro / Outro        → one clip per bar (~4 beats), slow dissolves
//   Breakdown / Bridge   → one clip per 2 bars, maximum calm
//   Verse                → one clip per 2 beats
//   Pre-chorus           → one clip per beat
//   Buildup (early half) → one clip per beat
//   Buildup (late half)  → flash: sub-beat clips (~0.5 beat), rapid cycle
//   Chorus / Drop        → hero: land clip 1 on bar downbeat (2-beat hold), then 1-beat cuts
//
// All cuts snap to an integer multiple of the beat grid.
// Clips are never reused (same assetID + clipOffset pair used at most once).
// Hero slots (chorus/drop) prioritise high-score video assets.

final class SequencerService: SequencerServiceProtocol {

    static let shared = SequencerService()
    private init() {}

    func buildSequence(
        title: String,
        settings: MontageSettings,
        assets: [MediaAsset],
        motionPrompts: [MotionPrompt],
        beatmap: Beatmap,
        onProgress: @escaping (Double, String) -> Void
    ) async -> MontagePlan {

        let promptMap = Dictionary(uniqueKeysWithValues: motionPrompts.map { ($0.assetID, $0) })

        // Candidates: scored assets above threshold, ranked by visual energy for mixing
        let scored = assets.filter { ($0.analysisScore ?? 0) > 0.3 }
        let candidates = scored.sorted { visualEnergy($0) > visualEnergy($1) }
        let fallbackCandidates = assets.sorted { visualEnergy($0) > visualEnergy($1) }

        onProgress(0.05, "Filtering \(candidates.count) candidates...")
        logger.info("Sequencer: \(candidates.count) candidates from \(assets.count) assets")

        // Build time slots from the beatmap
        let beatDur = beatmap.beatDuration
        let barStarts = beatmap.barStarts(beatsPerBar: 4)
        let timeSlots = buildTimeSlots(from: beatmap, beatDur: beatDur, barStarts: barStarts)
        onProgress(0.20, "Built \(timeSlots.count) time slots from \(beatmap.sections.count) sections...")
        logger.info("Sequencer: \(timeSlots.count) time slots across \(beatmap.sections.count) sections")

        let pool = candidates.isEmpty ? fallbackCandidates : candidates
        var usedKeys = Set<String>()    // (assetID)_(clipOffset) — prevents exact clip reuse
        var sequence: [MontageSequenceItem] = []
        var excludedIDs: [String] = []
        let totalDuration = beatmap.durationSeconds
        var position = 0

        let totalSlots = timeSlots.count
        for (slotIndex, slot) in timeSlots.enumerated() {
            guard slot.startTime < totalDuration else { break }

            if slotIndex % max(1, totalSlots / 10) == 0 {
                let prog = Double(slotIndex + 1) / Double(max(totalSlots, 1))
                onProgress(0.20 + prog * 0.70, "Placing clip \(position + 1) of ~\(totalSlots)...")
            }

            guard let asset = selectAsset(for: slot, from: pool, used: usedKeys) else { continue }
            usedKeys.insert(clipKey(asset))

            let prompt = promptMap[asset.id]
            let energy = Float(beatmap.energy(at: slot.startTime))

            let item = MontageSequenceItem(
                position: position,
                assetID: asset.id,
                startTime: slot.startTime,
                endTime: min(slot.endTime, totalDuration),
                transitionIn: transitionIn(for: slot, position: position),
                transitionOut: transitionOut(for: slot),
                motionPrompt: prompt?.prompt ?? "",
                motionIntensity: prompt?.motionIntensity ?? energy,
                beatAligned: slot.beatAligned,
                confidenceScore: asset.analysisScore ?? 0.7,
                sectionType: slot.section.type,
                selectionReason: selectionReason(for: asset, slot: slot),
                clipOffset: asset.clipStartTime ?? 0
            )
            sequence.append(item)
            position += 1
        }

        onProgress(0.95, "Finalizing \(sequence.count) clips...")
        logger.info("Sequencer: assigned \(sequence.count) clips")

        let usedIDs = Set(sequence.map(\.assetID))
        excludedIDs = pool.filter { !usedIDs.contains($0.id) }.map(\.id)
        let moodArc = buildMoodArc(from: beatmap, sequence: sequence)

        return MontagePlan(
            title: title,
            settings: settings,
            sequence: sequence,
            moodArc: moodArc,
            excludedAssetIDs: excludedIDs
        )
    }

    // MARK: - Time Slot Building

    private struct TimeSlot {
        var startTime: Double
        var endTime: Double
        var section: BeatSection
        var beatAligned: Bool
        var isFlash: Bool           // true during buildup late-phase flash sequences
    }

    private func buildTimeSlots(from beatmap: Beatmap, beatDur: Double, barStarts: [Double]) -> [TimeSlot] {
        var slots: [TimeSlot] = []

        // Song-level energy median drives overall pace:
        // a uniformly fast song compresses all clip durations; a slow song expands them.
        let allEnergies = beatmap.sections.map(\.energyAvg).sorted()
        let songMedian = allEnergies.isEmpty ? 0.5 : allEnergies[allEnergies.count / 2]

        for section in beatmap.sections {
            let sectionBeats = beatmap.beats.filter { $0 >= section.start && $0 < section.end }
            let sectionBars  = barStarts.filter      { $0 >= section.start && $0 < section.end }
            guard !sectionBeats.isEmpty else { continue }

            switch section.type {
            case .buildup:
                appendBuildupSlots(beats: sectionBeats, section: section, beatDur: beatDur, to: &slots)
            case .chorus, .drop:
                appendHeroSlots(bars: sectionBars, beats: sectionBeats, beatDur: beatDur,
                                section: section, to: &slots)
            default:
                let n = beatsPerSlot(type: section.type, sectionEnergy: section.energyAvg,
                                     songMedian: songMedian)
                if n >= 4 {
                    appendBarSlots(bars: sectionBars, fallback: sectionBeats, barsPerSlot: n / 4,
                                   section: section, isFlash: false, to: &slots)
                } else {
                    appendBeatSlots(beats: sectionBeats, step: max(1, n),
                                    section: section, isFlash: false, to: &slots)
                }
            }
        }
        return slots
    }

    /// Beats per clip for non-hero, non-buildup sections.
    ///
    /// The base rate comes from section type. Two adjustments are then applied:
    ///  • Global: a fast song (high median energy) halves all base durations so even
    ///    intro sections cut quickly when the track is energetic throughout.
    ///  • Local: a section notably hotter than the song median trims further;
    ///    a notably calmer section holds longer.
    private func beatsPerSlot(type: SectionType, sectionEnergy: Double, songMedian: Double) -> Int {
        let base: Int
        switch type {
        case .breakdown, .bridge: base = 8   // 2 bars
        case .intro, .outro:      base = 4   // 1 bar
        case .verse:              base = 2   // half-bar
        case .preChorus:          base = 1
        case .buildup, .chorus, .drop: base = 1  // handled separately
        }

        // Fast song globally (median > 0.6): compress all sections
        let adjusted = songMedian > 0.6 ? max(1, base / 2) : base

        // Section hotter than median → faster cuts
        if sectionEnergy > songMedian * 1.35 { return max(1, adjusted / 2) }
        // Section cooler than median → slower cuts (cap at 8 beats = 2 bars)
        if sectionEnergy < songMedian * 0.65 { return min(8, adjusted * 2) }
        return adjusted
    }

    /// One clip per N bars; falls back to beats when no bar grid available.
    private func appendBarSlots(bars: [Double], fallback: [Double], barsPerSlot: Int,
                                section: BeatSection, isFlash: Bool, to slots: inout [TimeSlot]) {
        let points = bars.isEmpty ? fallback : bars
        var i = 0
        while i < points.count {
            let start = points[i]
            let nextIdx = i + barsPerSlot
            let end = nextIdx < points.count ? points[nextIdx] : section.end
            let safeEnd = min(end, section.end)
            if safeEnd > start {
                slots.append(TimeSlot(startTime: start, endTime: safeEnd,
                                      section: section, beatAligned: true, isFlash: isFlash))
            }
            i += barsPerSlot
        }
    }

    /// One clip per N beats.
    private func appendBeatSlots(beats: [Double], step: Int, section: BeatSection,
                                 isFlash: Bool, to slots: inout [TimeSlot]) {
        var i = 0
        while i < beats.count {
            let start = beats[i]
            let nextIdx = i + step
            let end = nextIdx < beats.count ? beats[nextIdx] : section.end
            let safeEnd = min(end, section.end)
            if safeEnd > start {
                slots.append(TimeSlot(startTime: start, endTime: safeEnd,
                                      section: section, beatAligned: true, isFlash: isFlash))
            }
            i += step
        }
    }

    /// Buildup: first half = 1-beat clips; second half = flash (0.5-beat synthetic grid).
    private func appendBuildupSlots(beats: [Double], section: BeatSection,
                                    beatDur: Double, to slots: inout [TimeSlot]) {
        guard !beats.isEmpty else { return }
        let midpoint = section.start + (section.end - section.start) * 0.5
        let earlyBeats = beats.filter { $0 < midpoint }
        let lateStart = beats.first(where: { $0 >= midpoint }) ?? midpoint

        // Early: 1-beat cuts (not flash)
        appendBeatSlots(beats: earlyBeats, step: 1, section: section, isFlash: false, to: &slots)

        // Late: rapid half-beat flash
        let halfBeat = beatDur * 0.5
        var t = lateStart
        while t < section.end {
            let end = min(t + halfBeat, section.end)
            if end - t > beatDur * 0.15 {
                slots.append(TimeSlot(startTime: t, endTime: end,
                                      section: section, beatAligned: false, isFlash: true))
            }
            t = end
        }
    }

    /// Chorus / Drop: first clip anchored to bar 1 downbeat with a 2-beat hold, then 1-beat cuts.
    private func appendHeroSlots(bars: [Double], beats: [Double], beatDur: Double,
                                 section: BeatSection, to slots: inout [TimeSlot]) {
        let anchor = bars.first ?? beats.first ?? section.start
        let heroEnd = min(anchor + beatDur * 2, section.end)

        // Hero hold (2 beats)
        if heroEnd > anchor {
            slots.append(TimeSlot(startTime: anchor, endTime: heroEnd,
                                  section: section, beatAligned: true, isFlash: false))
        }

        // 1-beat cuts for the rest of the section
        let remainingBeats = beats.filter { $0 >= heroEnd }
        appendBeatSlots(beats: remainingBeats, step: 1, section: section, isFlash: false, to: &slots)
    }

    // MARK: - Energy-Aware Clip Selection

    /// Visual energy proxy: emotionScore × 0.6 + noveltyScore × 0.4; video gets +0.1 boost.
    private func visualEnergy(_ asset: MediaAsset) -> Float {
        let e = asset.emotionScore ?? 0.5
        let n = asset.noveltyScore ?? 0.5
        let videoBoost: Float = asset.isVideo ? 0.1 : 0
        return min(1.0, e * 0.6 + n * 0.4 + videoBoost)
    }

    /// Preferred visual-energy range for each section type.
    private func preferredEnergyRange(for type: SectionType) -> ClosedRange<Float> {
        switch type {
        case .intro, .outro:          return 0.0...0.45
        case .breakdown, .bridge:     return 0.0...0.45
        case .verse:                  return 0.3...0.65
        case .preChorus:              return 0.45...0.75
        case .buildup:                return 0.0...1.0   // any — maximise variety
        case .chorus, .drop:          return 0.55...1.0
        }
    }

    private func clipKey(_ asset: MediaAsset) -> String {
        "\(asset.id)_\(asset.clipStartTime ?? 0)"
    }

    private func selectAsset(for slot: TimeSlot, from pool: [MediaAsset], used: Set<String>) -> MediaAsset? {
        let isHero = slot.section.type == .drop || slot.section.type == .chorus
        let range = preferredEnergyRange(for: slot.section.type)

        // Hero slots: prefer unused video with high energy first
        if isHero {
            if let video = pool.first(where: { !used.contains(clipKey($0)) && $0.isVideo && visualEnergy($0) >= 0.5 }) {
                return video
            }
        }

        // Try an unused asset in the preferred energy range
        if let asset = pool.first(where: { !used.contains(clipKey($0)) && range.contains(visualEnergy($0)) }) {
            return asset
        }

        // Fallback: any unused asset
        if let asset = pool.first(where: { !used.contains(clipKey($0)) }) {
            return asset
        }

        // Pool exhausted — allow reuse (hero: highest energy; others: lowest, to start fresh)
        return isHero ? pool.first : pool.last
    }

    // MARK: - Transition Selection

    private func transitionIn(for slot: TimeSlot, position: Int) -> TransitionType {
        if position == 0 { return .fadeFromBlack }
        if slot.isFlash { return .hardCut }
        switch slot.section.type {
        case .drop:                return .flashWhite
        case .chorus:              return .crossfade
        case .buildup:             return .hardCut
        case .breakdown, .bridge:  return .dissolve
        case .intro, .outro:       return .dissolve
        default:                   return .hardCut
        }
    }

    private func transitionOut(for slot: TimeSlot) -> TransitionType {
        if slot.isFlash { return .hardCut }
        switch slot.section.type {
        case .drop:           return .hardCut
        case .outro:          return .dissolve
        case .breakdown:      return .crossfade
        default:              return .hardCut
        }
    }

    // MARK: - Selection Reason

    private func selectionReason(for asset: MediaAsset, slot: TimeSlot) -> String {
        var reasons: [String] = []
        if let q = asset.qualityScore, q > 0.8   { reasons.append("sharp & well-exposed") }
        if let e = asset.emotionScore, e > 0.75  { reasons.append("strong emotional valence") }
        if let n = asset.noveltyScore, n > 0.7   { reasons.append("visually distinct") }
        if slot.section.type == .drop || slot.section.type == .chorus { reasons.append("hero slot") }
        if asset.isVideo                           { reasons.append("video") }
        if slot.isFlash                            { reasons.append("buildup flash") }
        if slot.beatAligned                        { reasons.append("beat-aligned") }
        if reasons.isEmpty { reasons.append("balanced score") }
        return reasons.joined(separator: " · ")
    }

    // MARK: - Mood Arc

    private func buildMoodArc(from beatmap: Beatmap, sequence: [MontageSequenceItem]) -> [MoodPoint] {
        guard !beatmap.energyCurve.isEmpty else { return [] }
        let total = beatmap.durationSeconds
        return beatmap.energyCurve.compactMap { point in
            guard total > 0 else { return nil }
            let valence = 0.4 + point.energy * 0.6
            return MoodPoint(
                position: point.time / total,
                valence: valence,
                energy: point.energy,
                label: beatmap.section(at: point.time)?.type.rawValue ?? ""
            )
        }
    }
}
