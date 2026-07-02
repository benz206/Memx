import Foundation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "sequencer")

// MARK: - SequencerPreflight

struct SequencerPreflight: Hashable {
    let requiredClipCount: Int        // slots we'll emit
    let availableClipCount: Int       // eligible assets in the pool
    let estimatedShortfall: Int       // max(0, required - available)
    let estimatedShortfallSeconds: Double  // rough seconds that would repeat
    var hasShortfall: Bool { estimatedShortfall > 0 }
}

// MARK: - SequencerServiceProtocol

protocol SequencerServiceProtocol {
    func buildSequence(
        title: String,
        settings: MontageSettings,
        assets: [MediaAsset],
        beatmap: Beatmap,
        onProgress: @escaping (Double, String) -> Void
    ) async -> MontagePlan

    func preflight(
        settings: MontageSettings,
        assets: [MediaAsset],
        beatmap: Beatmap
    ) -> SequencerPreflight
}

// MARK: - SequencerService
// Musical-arc cut planner: per-section beat patterns, dramatic arc intensity scaling,
// scored asset selection, beat-impact transitions, peak-aligned clip offsets,
// breath shots every ~28 bars, and content-aware minimum durations.
// Deterministic given identical inputs.

final class SequencerService: SequencerServiceProtocol {

    static let shared = SequencerService()
    private init() {}

    // MARK: - Public API

    func buildSequence(
        title: String,
        settings: MontageSettings,
        assets: [MediaAsset],
        beatmap: Beatmap,
        onProgress: @escaping (Double, String) -> Void
    ) async -> MontagePlan {

        let scored           = assets.filter { ($0.analysisScore ?? 0) > 0.3 }
        let candidates       = scored.sorted { visualEnergy($0) > visualEnergy($1) }
        let fallbackCandidates = assets.sorted { visualEnergy($0) > visualEnergy($1) }

        onProgress(0.05, "Filtering \(candidates.count) candidates...")
        logger.info("Sequencer: \(candidates.count) candidates from \(assets.count) assets")

        let beatDur        = beatmap.beatDuration
        let barStarts      = beatmap.barStarts(beatsPerBar: 4)
        let arcIntensities = buildArcIntensities(sections: beatmap.sections)

        var timeSlots = buildTimeSlots(from: beatmap, beatDur: beatDur,
                                       barStarts: barStarts, arcIntensities: arcIntensities,
                                       vibe: settings.vibe)
        applyBreathShots(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        applySustainedVocalHolds(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        applyHookSlots(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        applyAnticipationHold(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        splitLongSlotsForPhotos(&timeSlots, beatDur: beatDur, beatmap: beatmap, vibe: settings.vibe)

        onProgress(0.20, "Built \(timeSlots.count) time slots from \(beatmap.sections.count) sections...")
        logger.info("Sequencer: \(timeSlots.count) time slots across \(beatmap.sections.count) sections, \(beatmap.hooks.count) hooks")

        let pool          = candidates.isEmpty ? fallbackCandidates : candidates
        // Searchable text per asset is slot-independent; build it once instead
        // of per (slot × asset) inside scoring.
        let semanticTexts = Dictionary(pool.map { ($0.id, semanticText(for: $0)) },
                                       uniquingKeysWith: { first, _ in first })
        let chronoPositions = chronologyPositions(for: pool)
        var usedKeys      = Set<String>()
        var sequence      = [MontageSequenceItem]()
        let totalDuration = beatmap.durationSeconds
        var position      = 0
        var prevAsset: MediaAsset?   = nil
        var prevSection: BeatSection? = nil
        var prevSlotStart: Double?   = nil
        // Déjà-vu: cluster key -> (signatureIndex -> asset) for forced reuse on repeats.
        var hookAnchorAssets = [Double: [Int: MediaAsset]]()

        let sectionFirstIDs = buildSectionFirstSlotIDs(from: timeSlots)
        let flashAllowed    = flashBudgetSlotIDs(slots: timeSlots, beatmap: beatmap,
                                                 vibe: settings.vibe)
        let totalSlots      = timeSlots.count

        // Hero-first pass: priority moments claim assets from the full pool
        // before chronological fill can spend them on a verse.
        let reserved = reservePriorityAssets(
            slots: timeSlots, pool: pool, sectionFirstIDs: sectionFirstIDs,
            arcIntensities: arcIntensities, settings: settings,
            semanticTexts: semanticTexts, chronoPositions: chronoPositions,
            totalDuration: totalDuration)
        usedKeys.formUnion(reserved.values.map { clipKey($0) })

        for (slotIndex, slot) in timeSlots.enumerated() {
            guard slot.startTime < totalDuration else { break }

            if slotIndex % max(1, totalSlots / 10) == 0 {
                let prog = Double(slotIndex + 1) / Double(max(totalSlots, 1))
                onProgress(0.20 + prog * 0.70, "Placing clip \(position + 1) of ~\(totalSlots)...")
            }

            let arcIntensity = arcIntensities[slot.section.id] ?? 0.9

            // Déjà-vu: on hook repeats (repeatIndex > 0), force reuse of the
            // asset picked for the same signature-beat position on the first
            // occurrence, bypassing usedKeys.
            let forcedAsset: MediaAsset? = {
                guard let key = slot.hookClusterKey,
                      let rIdx = slot.hookRepeatIndex, rIdx > 0,
                      let sIdx = slot.hookSignatureIndex,
                      let anchored = hookAnchorAssets[key]?[sIdx] else { return nil }
                return anchored
            }()

            let asset: MediaAsset
            if let forced = forcedAsset {
                asset = forced
            } else if let claimed = reserved[slot.id] {
                asset = claimed
            } else if let picked = selectAsset(for: slot, from: pool, used: usedKeys,
                                               prev: prevAsset, arcIntensity: arcIntensity,
                                               settings: settings, semanticTexts: semanticTexts,
                                               chronoPositions: chronoPositions,
                                               slotProgress: slot.startTime / max(totalDuration, 0.01)) {
                asset = picked
            } else {
                continue
            }
            usedKeys.insert(clipKey(asset))

            // Record the first-occurrence asset for later hook repeats to reuse.
            if let key = slot.hookClusterKey,
               let rIdx = slot.hookRepeatIndex, rIdx == 0,
               let sIdx = slot.hookSignatureIndex {
                hookAnchorAssets[key, default: [:]][sIdx] = asset
            }

            let energy  = Float(beatmap.energy(at: slot.startTime))
            let isFirst = sectionFirstIDs.contains(slot.id)
            let isHero  = isFirst && (slot.section.type == .chorus || slot.section.type == .drop)

            let trans = transition(prev: prevAsset, prevSection: prevSection,
                                   prevSlotStart: prevSlotStart, next: asset,
                                   slot: slot, position: position,
                                   isFirstOfSection: isFirst, beatmap: beatmap,
                                   vibe: settings.vibe, flashAllowed: flashAllowed)

            let itemStart = max(0, beatmap.nearestBeat(to: slot.startTime))
            let snappedEnd = slot.isFlash ? slot.endTime : beatmap.nearestBeat(to: slot.endTime)
            let itemEnd   = min(max(itemStart + 0.01, snappedEnd), totalDuration)

            let peakBeat = slot.peakBeat ?? slot.startTime
            // Slow-motion holds: 0.75× keeps effective frame rate cinematic
            // on 30fps sources while clearly reading as a slow-mo moment.
            let speedFactor: Double = {
                guard asset.isVideo, slot.isAnticipationHold || slot.isVocalHold else { return 1.0 }
                return asset.duration >= slot.duration * 0.75 + 0.3 ? 0.75 : 1.0
            }()
            let clipOffset = Self.cutOnActionOffset(
                asset: asset, slotStart: slot.startTime,
                slotDuration: slot.duration, peakBeat: peakBeat,
                rate: speedFactor)

            let isArcPeak  = isHero && arcIntensity >= 0.95
            let isHookSlot = slot.hookClusterKey != nil
            let isHookReturn = isHookSlot && (slot.hookRepeatIndex ?? 0) > 0

            // Anticipation and sustained vocal holds use their spec'd
            // transition shapes. Flash exits belong to the anticipation hold
            // alone — entry flashes are budgeted in transition().
            let transitionIn: TransitionType = slot.isAnticipationHold ? .dissolve : trans
            let transitionOut: TransitionType = {
                if slot.isAnticipationHold { return .flashWhite }
                if slot.isVocalHold { return .crossfade }
                return .hardCut
            }()

            let item = MontageSequenceItem(
                position: position,
                assetID: asset.id,
                startTime: itemStart,
                endTime: itemEnd,
                transitionIn: transitionIn,
                transitionOut: transitionOut,
                motionIntensity: energy,
                beatAligned: slot.beatAligned,
                confidenceScore: asset.analysisScore ?? 0.7,
                sectionType: slot.section.type,
                selectionReason: selectionReason(for: asset, slot: slot,
                                                  isHero: isHero,
                                                  isArcPeak: isArcPeak,
                                                  isHookSlot: isHookSlot,
                                                  isHookReturn: isHookReturn,
                                                  isSlowMotion: speedFactor < 1),
                clipOffset: clipOffset,
                peakTime: peakBeat,
                isHookMoment: isHookSlot,
                isAnticipationHold: slot.isAnticipationHold,
                hookRepeatIndex: slot.hookRepeatIndex,
                gradingHint: gradingHint(for: settings.vibe, sectionType: slot.section.type),
                speedFactor: speedFactor
            )
            sequence.append(item)
            position      += 1
            prevAsset      = asset
            prevSection    = slot.section
            prevSlotStart  = slot.startTime
        }

        if var last = sequence.last, last.sectionType == .outro {
            last.transitionOut = .dissolve
            sequence[sequence.count - 1] = last
        }

        onProgress(0.95, "Finalizing \(sequence.count) clips...")
        logger.info("Sequencer: assigned \(sequence.count) clips")

        let usedIDs     = Set(sequence.map(\.assetID))
        let excludedIDs = pool.filter { !usedIDs.contains($0.id) }.map(\.id)
        let moodArc     = buildMoodArc(from: beatmap, sequence: sequence)

        return MontagePlan(
            title: title,
            settings: settings,
            sequence: sequence,
            moodArc: moodArc,
            excludedAssetIDs: excludedIDs
        )
    }

    // MARK: - Preflight

    func preflight(
        settings: MontageSettings,
        assets: [MediaAsset],
        beatmap: Beatmap
    ) -> SequencerPreflight {
        let beatDur        = beatmap.beatDuration
        let barStarts      = beatmap.barStarts(beatsPerBar: 4)
        let arcIntensities = buildArcIntensities(sections: beatmap.sections)

        var timeSlots = buildTimeSlots(from: beatmap, beatDur: beatDur,
                                       barStarts: barStarts, arcIntensities: arcIntensities,
                                       vibe: settings.vibe)
        applyBreathShots(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        applySustainedVocalHolds(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        applyHookSlots(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        applyAnticipationHold(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)
        splitLongSlotsForPhotos(&timeSlots, beatDur: beatDur, beatmap: beatmap, vibe: settings.vibe)

        let totalDuration = beatmap.durationSeconds
        let validSlots    = timeSlots.filter { $0.startTime < totalDuration }
        let requiredCount = validSlots.count

        // Mirror buildSequence pool selection: scored > 0.3, else fallback to all assets.
        let scored = assets.filter { ($0.analysisScore ?? 0) > 0.3 }
        let pool   = scored.isEmpty ? assets : scored
        let availableCount = pool.count

        let shortfall = max(0, requiredCount - availableCount)

        // Estimated seconds that would repeat: sum the trailing slot durations
        // beyond the unique pool capacity.
        let shortfallSeconds: Double
        if shortfall > 0 && !validSlots.isEmpty {
            let start = min(availableCount, validSlots.count)
            shortfallSeconds = validSlots[start..<validSlots.count]
                .reduce(0.0) { $0 + $1.duration }
        } else {
            shortfallSeconds = 0
        }

        logger.info("Preflight: required=\(requiredCount), available=\(availableCount), shortfall=\(shortfall), shortfallSec=\(shortfallSeconds, format: .fixed(precision: 1))")

        return SequencerPreflight(
            requiredClipCount: requiredCount,
            availableClipCount: availableCount,
            estimatedShortfall: shortfall,
            estimatedShortfallSeconds: shortfallSeconds
        )
    }

    // MARK: - TimeSlot

    private struct TimeSlot {
        let id: UUID
        var startTime: Double
        var endTime: Double
        var section: BeatSection
        var beatAligned: Bool
        var isFlash: Bool
        var peakBeat: Double?
        var isBreath: Bool
        var isVocalHold: Bool
        // Hook metadata — non-nil when the slot lands inside a detected hook.
        var hookClusterKey: Double?      // prototype (first-occurrence) hook startTime, stable across repeats
        var hookRepeatIndex: Int?        // 0, 1, 2… within-cluster chronological order
        var hookSignatureIndex: Int?     // which signature-beat within the hook this slot sits on
        var isAnticipationHold: Bool
        var duration: Double { endTime - startTime }

        init(startTime: Double, endTime: Double, section: BeatSection,
             beatAligned: Bool, isFlash: Bool = false,
             peakBeat: Double? = nil, isBreath: Bool = false,
             isVocalHold: Bool = false,
             hookClusterKey: Double? = nil, hookRepeatIndex: Int? = nil,
             hookSignatureIndex: Int? = nil, isAnticipationHold: Bool = false) {
            self.id          = UUID()
            self.startTime   = startTime
            self.endTime     = endTime
            self.section     = section
            self.beatAligned = beatAligned
            self.isFlash     = isFlash
            self.peakBeat    = peakBeat
            self.isBreath    = isBreath
            self.isVocalHold = isVocalHold
            self.hookClusterKey     = hookClusterKey
            self.hookRepeatIndex    = hookRepeatIndex
            self.hookSignatureIndex = hookSignatureIndex
            self.isAnticipationHold = isAnticipationHold
        }
    }

    // MARK: - CutPattern

    private struct CutPattern {
        let durationsInBeats: [Double]
        let isAnchoredToBar: Bool
    }

    // MARK: - Arc Intensity

    private func buildArcIntensities(sections: [BeatSection]) -> [UUID: Double] {
        let total = sections.count
        guard total > 0 else { return [:] }

        var result    = [UUID: Double]()
        var chorusIdx = 0
        var dropIdx   = 0
        let nChorus   = sections.filter { $0.type == .chorus }.count
        let nDrop     = sections.filter { $0.type == .drop   }.count

        for (i, section) in sections.enumerated() {
            let pos = Double(i) / Double(max(total - 1, 1))
            switch section.type {
            case .chorus:
                result[section.id] = heroArcIntensity(k: chorusIdx, n: nChorus)
                chorusIdx += 1
            case .drop:
                result[section.id] = heroArcIntensity(k: dropIdx, n: nDrop)
                dropIdx += 1
            case .outro:
                result[section.id] = max(0.4, 1.0 - 0.15 * pos)
            default:
                result[section.id] = 0.9
            }
        }
        return result
    }

    private func heroArcIntensity(k: Int, n: Int) -> Double {
        guard n > 1 else { return 1.0 }
        if k == 0     { return 0.75 }
        if k == n - 1 { return 1.0  }
        if k == 1     { return 0.9  }
        return 0.9 + 0.1 * Double(k - 1) / Double(max(n - 2, 1))
    }

    // MARK: - Cut Patterns

    private func baseCutPattern(for type: SectionType, leadsToDrop: Bool, vibe: MontageVibe) -> CutPattern {
        // Start with the canonical pattern, then layer vibe-specific mods.
        var pattern: CutPattern = {
            switch type {
            case .intro:
                return CutPattern(durationsInBeats: [8, 8],                        isAnchoredToBar: true)
            case .verse:
                return CutPattern(durationsInBeats: [4, 4, 2, 2, 2, 2, 4],         isAnchoredToBar: true)
            case .preChorus:
                return CutPattern(durationsInBeats: [2, 2, 1, 1, 0.5, 0.5, 1],     isAnchoredToBar: true)
            case .chorus:
                return CutPattern(durationsInBeats: [4, 1, 1, 1, 1, 2, 1, 1],      isAnchoredToBar: true)
            case .drop:
                return CutPattern(durationsInBeats: [1, 1, 1, 1, 0.5, 0.5, 1, 1], isAnchoredToBar: true)
            case .breakdown:
                return CutPattern(durationsInBeats: [16, 16],                      isAnchoredToBar: true)
            case .bridge:
                return CutPattern(durationsInBeats: [8, 8, 4, 4],                  isAnchoredToBar: true)
            case .outro:
                return CutPattern(durationsInBeats: [16, 16, 32],                  isAnchoredToBar: true)
            case .buildup:
                let durs: [Double] = leadsToDrop
                    ? [2, 2, 1, 1, 0.5, 0.5, 1, 0.5, 0.5]
                    : [2, 1, 1, 0.5, 0.5]
                return CutPattern(durationsInBeats: durs, isAnchoredToBar: leadsToDrop)
            }
        }()

        switch vibe {
        case .nostalgic:
            // Slow everything down ~40%.
            pattern = CutPattern(
                durationsInBeats: pattern.durationsInBeats.map { $0 * 1.4 },
                isAnchoredToBar: pattern.isAnchoredToBar
            )
        case .hype:
            // Sub-beat cuts mid-drop: insert a [0.5, 0.5] burst into the drop pattern.
            if type == .drop, pattern.durationsInBeats.count >= 3 {
                var durs = pattern.durationsInBeats
                let insertAt = durs.count / 2
                durs.insert(contentsOf: [0.5, 0.5], at: insertAt)
                pattern = CutPattern(durationsInBeats: durs, isAnchoredToBar: pattern.isAnchoredToBar)
            }
        case .cinematic, .wholesome, .funny, .travel:
            break
        }

        return pattern
    }

    private func adjustedPattern(base: CutPattern, sectionType: SectionType,
                                  arcIntensity: Double,
                                  encounterIndex k: Int, totalEncounters n: Int,
                                  sectionBeatCount: Int, storyRamp: Double,
                                  leadsToDrop: Bool) -> CutPattern {
        var durs = base.durationsInBeats

        // Buildup leading to drop: trim/pad from front so last slot lands on last beat
        if sectionType == .buildup && leadsToDrop && sectionBeatCount > 0 {
            let patTotal = durs.reduce(0.0, +)
            let secTotal = Double(sectionBeatCount)
            if secTotal < patTotal {
                var kept = [Double]()
                var rem  = secTotal
                for d in durs.reversed() {
                    guard rem > 0 else { break }
                    kept.append(min(d, rem))
                    rem -= d
                }
                durs = kept.reversed()
            } else if secTotal > patTotal {
                var extra = secTotal - patTotal
                var pad   = [Double]()
                while extra >= 4 { pad.append(4); extra -= 4 }
                if extra > 0.01 { pad.append(extra) }
                durs = pad + durs
            }
            return CutPattern(durationsInBeats: durs, isAnchoredToBar: true)
        }

        // Story ramp: start with readable cuts, then tighten toward the payoff.
        // At the drop/late chorus this roughly doubles clip density, giving the
        // "Beauty and a Beat" style release where more memories flood in.
        if sectionType != .intro && sectionType != .outro && sectionType != .breakdown {
            let multiplier = max(0.45, 1.0 - storyRamp * 0.50)
            durs = durs.map { duration in
                guard duration <= 8 else { return duration }
                let floor: Double = sectionType == .verse ? 2.0 : 0.5
                return max(floor, duration * multiplier)
            }
        }

        if leadsToDrop && (sectionType == .verse || sectionType == .preChorus || sectionType == .buildup) {
            durs.append(contentsOf: [1, 1, 0.5, 0.5])
        }

        if sectionType == .drop || (sectionType == .chorus && storyRamp > 0.65) {
            durs.append(contentsOf: [0.5, 0.5, 1, 0.5, 0.5])
        }

        // Soft version: slow down fast tail for low-intensity sections
        if arcIntensity < 0.8 {
            durs = durs.map { $0 <= 2.0 ? $0 * 2.0 : $0 }
        }

        // Choruses can open with a brief hero breath, but drops stay punchy.
        if sectionType == .chorus && !durs.isEmpty {
            durs[0] = (k == n - 1 && n > 1) ? 4.0 : 2.0
            if arcIntensity >= 0.95 {
                durs.insert(4.0, at: 0)
            }
        }

        return CutPattern(durationsInBeats: durs, isAnchoredToBar: base.isAnchoredToBar)
    }

    // Cut density follows the music's measured busyness, not just the
    // section label: the same fixed verse pattern shouldn't cut a sparse
    // ballad verse and a dense funk verse identically. Long-hold section
    // types keep their dramatic shape.
    private func densityAdjusted(_ pattern: CutPattern, section: BeatSection,
                                 sections: [BeatSection]) -> CutPattern {
        guard section.type != .intro, section.type != .outro, section.type != .breakdown,
              let density = section.onsetDensity else { return pattern }

        var weightedSum = 0.0
        var totalDuration = 0.0
        for s in sections {
            guard let d = s.onsetDensity, s.duration > 0 else { continue }
            weightedSum += d * s.duration
            totalDuration += s.duration
        }
        guard totalDuration > 0 else { return pattern }
        let mean = weightedSum / totalDuration
        guard mean > 0 else { return pattern }

        let ratio = density / mean
        let scale: Double
        if ratio > 1.35      { scale = 0.75 }   // busy passage: cut faster
        else if ratio < 0.65 { scale = 1.35 }   // sparse passage: let shots breathe
        else                 { return pattern }

        return CutPattern(
            durationsInBeats: pattern.durationsInBeats.map { max(0.5, $0 * scale) },
            isAnchoredToBar: pattern.isAnchoredToBar
        )
    }

    private func storyRampValue(sectionIndex: Int, sections: [BeatSection]) -> Double {
        guard !sections.isEmpty else { return 0 }
        let current = sections[sectionIndex]

        if current.type == .drop { return 1.0 }
        if current.type == .chorus {
            let chorusCount = sections.filter { $0.type == .chorus }.count
            guard chorusCount > 1 else { return 0.85 }
            let ordinal = sections.prefix(sectionIndex + 1).filter { $0.type == .chorus }.count - 1
            return min(1.0, 0.72 + Double(ordinal) / Double(max(chorusCount - 1, 1)) * 0.25)
        }

        if let payoffIndex = sections[sectionIndex...].firstIndex(where: { $0.type == .drop || $0.type == .chorus }) {
            let distance = payoffIndex - sectionIndex
            switch distance {
            case 0: return 0.90
            case 1: return 0.78
            case 2: return 0.55
            case 3: return 0.35
            default: return 0.12
            }
        }

        let global = Double(sectionIndex) / Double(max(sections.count - 1, 1))
        return max(0.10, min(0.45, global * 0.45))
    }

    // MARK: - Time Slot Building

    private func buildTimeSlots(from beatmap: Beatmap, beatDur: Double,
                                 barStarts: [Double], arcIntensities: [UUID: Double],
                                 vibe: MontageVibe) -> [TimeSlot] {
        var slots     = [TimeSlot]()
        var chorusIdx = 0
        var dropIdx   = 0
        let nChorus   = beatmap.sections.filter { $0.type == .chorus }.count
        let nDrop     = beatmap.sections.filter { $0.type == .drop   }.count

        for (idx, section) in beatmap.sections.enumerated() {
            let sectionBeats = beatmap.beats.filter { $0 >= section.start && $0 < section.end }
            let sectionBars  = barStarts.filter     { $0 >= section.start && $0 < section.end }
            guard !sectionBeats.isEmpty else { continue }

            let nextType    = idx + 1 < beatmap.sections.count ? beatmap.sections[idx + 1].type : nil
            let leadsToDrop = nextType == .drop || nextType == .chorus

            let k: Int; let n: Int
            switch section.type {
            case .chorus: k = chorusIdx; n = nChorus; chorusIdx += 1
            case .drop:   k = dropIdx;   n = nDrop;   dropIdx   += 1
            default:      k = 0; n = 1
            }

            let arcIntensity = arcIntensities[section.id] ?? 0.9
            let storyRamp = section.end <= beatmap.durationSeconds
                ? storyRampValue(sectionIndex: idx, sections: beatmap.sections)
                : 0
            let base    = baseCutPattern(for: section.type, leadsToDrop: leadsToDrop, vibe: vibe)
            let pattern = densityAdjusted(
                adjustedPattern(base: base, sectionType: section.type,
                                arcIntensity: arcIntensity,
                                encounterIndex: k, totalEncounters: n,
                                sectionBeatCount: sectionBeats.count,
                                storyRamp: storyRamp,
                                leadsToDrop: leadsToDrop),
                section: section, sections: beatmap.sections)

            emitSlots(for: section, pattern: pattern, beats: sectionBeats, bars: sectionBars,
                      beatDur: beatDur, beatmap: beatmap, to: &slots)
        }
        return slots
    }

    private func emitSlots(for section: BeatSection, pattern: CutPattern,
                           beats: [Double], bars: [Double], beatDur: Double,
                           beatmap: Beatmap, to slots: inout [TimeSlot]) {
        guard !pattern.durationsInBeats.isEmpty else { return }

        let anchorStart: Double = pattern.isAnchoredToBar ? (bars.first ?? section.start) : section.start
        var t      = anchorStart
        var patIdx = 0
        let patLen = pattern.durationsInBeats.count

        while t < section.end - beatDur * 0.1 {
            let dBeats = pattern.durationsInBeats[patIdx % patLen]
            patIdx += 1
            guard dBeats > 0 else { break }

            let rawEnd = t + dBeats * beatDur
            guard t < section.end else { break }
            let computedEnd = min(rawEnd, section.end)

            let isAccel = dBeats < 1.0

            let actualStart: Double
            let actualEnd: Double
            if isAccel {
                actualStart = t
                actualEnd   = min(computedEnd, section.end)
            } else {
                let snappedStart = beatmap.nearestBeat(to: t)
                let snappedEnd   = beatmap.nearestBeat(to: computedEnd)
                actualStart = snappedStart
                actualEnd   = min(snappedEnd, section.end)
            }

            guard actualEnd > actualStart + 0.01 else {
                t = isAccel ? rawEnd : max(rawEnd, actualStart + beatDur)
                continue
            }

            let dur      = actualEnd - actualStart
            let isFlash  = isAccel && dur < beatDur
            let aligned  = !isAccel
            let peakBeat = beatmap.strongestBeat(in: actualStart...actualEnd)

            slots.append(TimeSlot(startTime: actualStart, endTime: actualEnd,
                                  section: section, beatAligned: aligned,
                                  isFlash: isFlash, peakBeat: peakBeat))
            t = isAccel ? rawEnd : actualEnd
        }
    }

    // MARK: - Breath Shots

    private func applyBreathShots(to slots: inout [TimeSlot], beatmap: Beatmap, beatDur: Double) {
        let barDur         = beatDur * 4
        let breathInterval = barDur * 28
        let breathDur      = barDur * 4
        let eligible: Set<SectionType> = [.intro, .verse, .bridge, .breakdown, .outro]

        var i = 0
        while i < slots.count {
            guard eligible.contains(slots[i].section.type) else { i += 1; continue }

            let secID  = slots[i].section.id
            let secDur = slots[i].section.end - slots[i].section.start
            var j = i
            while j < slots.count && slots[j].section.id == secID { j += 1 }

            guard secDur > barDur * 24 else { i = j; continue }

            var breathCandidates = [Int]()
            var lastBreath = slots[i].section.start
            for idx in i..<j where slots[idx].startTime - lastBreath >= breathInterval * 0.85 {
                breathCandidates.append(idx)
                lastBreath = slots[idx].startTime
            }

            for breathIdx in breathCandidates.reversed() {
                guard breathIdx < slots.count, breathIdx + 1 < slots.count,
                      slots[breathIdx].section.id == secID else { continue }

                let lo = max(i, breathIdx - 2)
                let hi = min(j - 2, breathIdx + 2)
                guard lo <= hi else { continue }

                let targetIdx = (lo...hi).min(by: {
                    beatmap.energy(at: slots[$0].startTime) < beatmap.energy(at: slots[$1].startTime)
                }) ?? breathIdx

                let breathEnd   = min(slots[targetIdx].startTime + breathDur, slots[targetIdx].section.end)
                let breathRange = slots[targetIdx].startTime...breathEnd

                var removeEnd = targetIdx + 1
                while removeEnd < slots.count
                    && slots[removeEnd].section.id == secID
                    && slots[removeEnd].startTime < breathEnd { removeEnd += 1 }

                let merged = TimeSlot(startTime: slots[targetIdx].startTime, endTime: breathEnd,
                                      section: slots[targetIdx].section,
                                      beatAligned: slots[targetIdx].beatAligned,
                                      peakBeat: beatmap.strongestBeat(in: breathRange),
                                      isBreath: true)
                slots.replaceSubrange(targetIdx..<removeEnd, with: [merged])
                j = j - (removeEnd - targetIdx) + 1
            }

            i = j
        }
    }

    // MARK: - Sustained Vocal Holds
    // Strong vocal peaks are treated as likely stretched melodic phrases. When
    // they occur outside a buildup/drop, merge surrounding cuts into a 4-8 beat
    // hold so the vocal can open up emotionally instead of being overcut.

    private func applySustainedVocalHolds(to slots: inout [TimeSlot], beatmap: Beatmap, beatDur: Double) {
        guard !beatmap.vocalPeaks.isEmpty, !slots.isEmpty else { return }

        for vocal in beatmap.vocalPeaks.sorted(by: { $0.time < $1.time }) where vocal.intensity >= 0.65 {
            guard let section = beatmap.section(at: vocal.time),
                  section.type != .buildup,
                  section.type != .drop,
                  section.type != .intro,
                  section.type != .outro else { continue }

            let holdBeats: Double = vocal.intensity >= 0.85 ? 8 : 4
            let holdDuration = holdBeats * beatDur
            let phraseStart = beatmap.phraseStart(before: vocal.time)
            let rawStart = phraseStart.map { abs(vocal.time - $0) <= beatDur * 4 ? $0 : vocal.time - beatDur } ?? (vocal.time - beatDur)
            let holdStart = max(section.start, beatmap.nearestBeat(to: rawStart))
            let holdEnd = min(section.end, beatmap.nearestBeat(to: holdStart + holdDuration))
            guard holdEnd > holdStart + beatDur * 2 else { continue }

            slots.removeAll {
                $0.hookClusterKey == nil
                    && !$0.isAnticipationHold
                    && $0.startTime < holdEnd
                    && $0.endTime > holdStart
            }

            slots.append(TimeSlot(
                startTime: holdStart,
                endTime: holdEnd,
                section: section,
                beatAligned: true,
                isFlash: false,
                peakBeat: beatmap.strongestBeat(in: holdStart...holdEnd),
                isBreath: false,
                isVocalHold: true
            ))
            slots.sort { $0.startTime < $1.startTime }
        }
    }

    // MARK: - Hook Slots
    // Replace in-range time slots with signature-beat-aligned slots. Each
    // consecutive signature beat gets one slot; duration = gap to next
    // signature beat (or bar length if only one signature beat). If the
    // cluster has only a single repetition this still runs (hooks array
    // enforces cluster size ≥ 2 at detection time).

    private func applyHookSlots(to slots: inout [TimeSlot], beatmap: Beatmap, beatDur: Double) {
        guard !beatmap.hooks.isEmpty else { return }
        let barDur = beatDur * 4

        // Cluster key: hooks arrive sorted by startTime with cluster-local
        // repeatIndex. The prototype for a repeat is the nearest earlier hook
        // with repeatIndex == 0 and a matching duration (within 30%); its
        // startTime is the stable key shared across the cluster.
        func prototypeKey(for hook: HookMoment, among all: [HookMoment]) -> Double {
            if hook.repeatIndex == 0 { return hook.startTime }
            let dur = hook.endTime - hook.startTime
            let earlier = all.filter {
                $0.startTime < hook.startTime
                    && $0.repeatIndex == 0
                    && abs(($0.endTime - $0.startTime) - dur) < dur * 0.3
            }
            return earlier.last?.startTime ?? hook.startTime
        }

        for hook in beatmap.hooks {
            let clusterKey = prototypeKey(for: hook, among: beatmap.hooks)
            let start = hook.startTime
            let end   = hook.endTime
            guard end > start + beatDur else { continue }

            // Build signature-beat slot boundaries. If no signature beats,
            // fall back to a single bar-length slot.
            let sigs = hook.signatureBeats.filter { $0 >= start && $0 < end }.sorted()
            let boundaries: [Double]
            if sigs.isEmpty {
                boundaries = [start]
            } else {
                boundaries = sigs
            }

            // Find section that contains the hook (use nearest).
            guard let section = beatmap.sections.first(where: {
                $0.start <= start && start < $0.end
            }) ?? beatmap.sections.last else { continue }

            var hookSlots = [TimeSlot]()
            for (sIdx, b) in boundaries.enumerated() {
                let nextBoundary = sIdx + 1 < boundaries.count ? boundaries[sIdx + 1] : end
                let slotEnd = min(nextBoundary, end)
                // Guard against too-short leading stub if signature beats don't
                // cover the very start of the hook.
                let slotStart = max(start, b)
                guard slotEnd > slotStart + 0.05 else { continue }

                // If there's a gap between the hook start and the first sig
                // beat, swallow it into the first sig-beat's slot (so we don't
                // leave a naked leading chunk un-styled).
                let finalStart = (sIdx == 0) ? start : slotStart

                let peak = beatmap.strongestBeat(in: finalStart...slotEnd)

                hookSlots.append(TimeSlot(
                    startTime: finalStart,
                    endTime: slotEnd,
                    section: section,
                    beatAligned: true,
                    isFlash: (slotEnd - finalStart) < beatDur,
                    peakBeat: peak,
                    isBreath: false,
                    hookClusterKey: clusterKey,
                    hookRepeatIndex: hook.repeatIndex,
                    hookSignatureIndex: sIdx
                ))
            }

            // Single-signature-beat fallback: expand to bar length.
            if hookSlots.count == 1, let only = hookSlots.first {
                let bumpedEnd = min(only.startTime + barDur, end)
                hookSlots[0] = TimeSlot(
                    startTime: only.startTime,
                    endTime: bumpedEnd,
                    section: only.section,
                    beatAligned: only.beatAligned,
                    isFlash: only.isFlash,
                    peakBeat: only.peakBeat,
                    isBreath: false,
                    hookClusterKey: clusterKey,
                    hookRepeatIndex: hook.repeatIndex,
                    hookSignatureIndex: 0
                )
            }
            guard !hookSlots.isEmpty else { continue }

            // Remove any existing slots that overlap this hook's range, then
            // insert hook slots in order, preserving chronological sort.
            slots.removeAll { $0.startTime >= start && $0.startTime < end }
            slots.append(contentsOf: hookSlots)
            slots.sort { $0.startTime < $1.startTime }
        }
    }

    // MARK: - Anticipation Hold
    // Before the final hook (if chorus/drop), replace the last non-hook slot
    // in that interval with a 1-bar hold marked isAnticipationHold. The
    // emission loop will pair it with .dissolve in / .flashWhite out.

    private func applyAnticipationHold(to slots: inout [TimeSlot], beatmap: Beatmap, beatDur: Double) {
        guard let finalStart = beatmap.finalHookStart else { return }
        // Validate the final hook lives in a chorus/drop section.
        guard let finalSection = beatmap.sections.first(where: {
            $0.start <= finalStart && finalStart < $0.end
        }), (finalSection.type == .chorus || finalSection.type == .drop) else { return }

        let barDur = beatDur * 4
        let holdStart = finalStart - barDur
        guard holdStart > 0 else { return }
        let holdEnd   = finalStart

        // Find the last slot whose startTime is in [holdStart - barDur, finalStart)
        // and is not itself a hook slot. If none, prepend a new slot.
        let priorIdx = slots.lastIndex(where: {
            $0.hookClusterKey == nil && $0.startTime < holdEnd && $0.endTime > holdStart - barDur
        })

        // Find the section the hold sits in (prefer the slot's own section if found).
        let sectionForHold: BeatSection = {
            if let i = priorIdx { return slots[i].section }
            return beatmap.sections.first(where: { $0.start <= holdStart && holdStart < $0.end })
                ?? finalSection
        }()

        let peak = beatmap.strongestBeat(in: holdStart...holdEnd)
        let hold = TimeSlot(
            startTime: holdStart,
            endTime: holdEnd,
            section: sectionForHold,
            beatAligned: true,
            isFlash: false,
            peakBeat: peak,
            isBreath: false,
            isAnticipationHold: true
        )

        if let i = priorIdx {
            // Replace overlapping prior (non-hook) slots in the hold window.
            var removeUpper = i + 1
            while removeUpper > 0,
                  slots[removeUpper - 1].hookClusterKey == nil,
                  slots[removeUpper - 1].endTime > holdStart {
                if removeUpper - 2 < 0 { break }
                if slots[removeUpper - 2].endTime <= holdStart { break }
                removeUpper -= 1
            }
            var removeLower = i
            while removeLower >= 0,
                  slots[removeLower].hookClusterKey == nil,
                  slots[removeLower].startTime >= holdStart - 0.01,
                  slots[removeLower].startTime < holdEnd {
                removeLower -= 1
            }
            let lo = removeLower + 1
            let hi = min(slots.count, i + 1)
            if lo <= hi, lo < slots.count {
                slots.replaceSubrange(lo..<hi, with: [hold])
            } else {
                slots.append(hold)
                slots.sort { $0.startTime < $1.startTime }
            }
        } else {
            slots.append(hold)
            slots.sort { $0.startTime < $1.startTime }
        }
    }

    // MARK: - Split Long Slots For Photos
    // Product invariant: photos should hold roughly 1.2–1.8 s so the edit
    // feels alive without flickering. The target snaps to a musical beat count
    // (1 / 2 / 4) based on tempo so cuts always land on strong beats. Hero
    // holds, breath shots, anticipation holds, hook openers, and sustained
    // section types (outro/breakdown/bridge) are exempt so the dramatic shape
    // survives. Do not change the target without discussing pacing with product.

    /// Target musical length for a non-hero photo hold, snapped to {1, 2, 4} beats.
    /// Aims for ~1.4 s of screen time — slow enough to read, fast enough to feel.
    private func photoHoldTargetBeats(beatDur: Double, section: SectionType, vibe: MontageVibe) -> Double {
        var targetSeconds: Double
        switch section {
        case .chorus, .drop:  targetSeconds = 1.0   // peak energy: a touch faster
        case .verse:          targetSeconds = 1.4
        case .preChorus:      targetSeconds = 1.2
        case .buildup:        targetSeconds = 1.2
        default:              targetSeconds = 1.4
        }
        if vibe == .nostalgic {
            targetSeconds *= 1.5
        }
        let raw = targetSeconds / max(beatDur, 0.01)
        if raw < 1.5 { return 1 }
        if raw < 3.0 { return 2 }
        return 4
    }

    private func splitLongSlotsForPhotos(_ slots: inout [TimeSlot],
                                         beatDur: Double,
                                         beatmap: Beatmap,
                                         vibe: MontageVibe) {
        let veryShortBeat = beatDur <= 0.05
        guard !veryShortBeat else { return }

        var sectionHeroSlotIDs = Set<UUID>()
        var seenHeroSection    = Set<UUID>()
        for slot in slots {
            guard slot.section.type == .chorus || slot.section.type == .drop else { continue }
            if seenHeroSection.insert(slot.section.id).inserted {
                sectionHeroSlotIDs.insert(slot.id)
            }
        }

        var result = [TimeSlot]()
        result.reserveCapacity(slots.count * 2)
        var splitCount = 0

        for slot in slots {
            let beatsInSlot = slot.duration / beatDur
            let targetBeats = photoHoldTargetBeats(beatDur: beatDur, section: slot.section.type, vibe: vibe)

            let exempt = slot.isAnticipationHold
                || slot.isVocalHold
                || slot.isBreath
                || slot.isFlash
                || (slot.hookClusterKey != nil && slot.hookSignatureIndex == 0)
                || slot.section.type == .outro
                || slot.section.type == .breakdown
                || slot.section.type == .bridge
                || sectionHeroSlotIDs.contains(slot.id)

            // Only split when the slot is meaningfully longer than the target.
            // A 10% tolerance keeps patterns that already produce on-target
            // lengths (e.g. a 2-beat slot when targetBeats == 2) intact.
            if exempt || beatsInSlot <= targetBeats * 1.1 {
                result.append(slot)
                continue
            }

            // Pick interior beats that land on target-beat multiples away from
            // the slot start. This produces even 2-beat (or 4-beat) sub-slots
            // snapped to the beatgrid.
            let chunkDur = targetBeats * beatDur
            var boundaries: [Double] = [slot.startTime]
            var cursor = slot.startTime + chunkDur
            while cursor < slot.endTime - beatDur * 0.25 {
                let nearest = beatmap.nearestBeat(to: cursor)
                if nearest > (boundaries.last ?? slot.startTime) + beatDur * 0.5,
                   nearest < slot.endTime - beatDur * 0.25 {
                    boundaries.append(nearest)
                }
                cursor += chunkDur
            }
            boundaries.append(slot.endTime)

            guard boundaries.count > 2 else {
                result.append(slot)
                continue
            }

            for bi in 0..<boundaries.count - 1 {
                let subStart = boundaries[bi]
                let subEnd   = boundaries[bi + 1]
                guard subEnd > subStart + 0.01 else { continue }

                let inheritedSigIdx: Int? = {
                    guard slot.hookClusterKey != nil else { return nil }
                    return bi == 0 ? slot.hookSignatureIndex : nil
                }()

                let sub = TimeSlot(
                    startTime: subStart,
                    endTime: subEnd,
                    section: slot.section,
                    beatAligned: true,
                    isFlash: false,
                    peakBeat: beatmap.strongestBeat(in: subStart...subEnd),
                    isBreath: false,
                    hookClusterKey: slot.hookClusterKey,
                    hookRepeatIndex: slot.hookRepeatIndex,
                    hookSignatureIndex: inheritedSigIdx,
                    isAnticipationHold: false
                )
                result.append(sub)
            }
            splitCount += 1
        }

        if splitCount > 0 {
            logger.info("Sequencer: split \(splitCount) long photo-eligible slots (target \(beatDur, format: .fixed(precision: 2))s/beat, total slots now \(result.count))")
        }
        slots = result
    }

    // MARK: - Grading Hint

    private func gradingHint(for vibe: MontageVibe, sectionType: SectionType?) -> GradingHint? {
        guard let t = sectionType else { return nil }
        switch vibe {
        case .nostalgic:
            return (t == .chorus || t == .drop) ? .golden : .nostalgic
        case .cinematic:
            if t == .breakdown || t == .bridge { return .desaturated }
            if t == .drop || t == .chorus       { return .contrasty }
            return nil
        case .hype:
            return t == .drop ? .contrasty : nil
        case .wholesome, .funny, .travel:
            return nil
        }
    }

    // MARK: - Section First Slot IDs

    private func buildSectionFirstSlotIDs(from slots: [TimeSlot]) -> Set<UUID> {
        var seen   = Set<UUID>()
        var firsts = Set<UUID>()
        for slot in slots where !seen.contains(slot.section.id) {
            firsts.insert(slot.id)
            seen.insert(slot.section.id)
        }
        return firsts
    }

    // MARK: - Flash Budget
    // Editors use a white flash 2–4 times per video, saved for the biggest
    // hits. The old rule flashed on every phrase start (~every 8 seconds).
    // Candidates in priority order: the anticipation hold's exit is implicit
    // (always flashes); this budget covers entries — each drop section, the
    // final chorus, hype-vibe hook returns, then the strongest detected hits.

    private static let maxFlashCount = 4

    private func flashBudgetSlotIDs(slots: [TimeSlot], beatmap: Beatmap,
                                    vibe: MontageVibe) -> Set<UUID> {
        var candidates = [(priority: Int, time: Double, id: UUID)]()

        var seenSections = Set<UUID>()
        let lastChorusID = slots.last(where: { $0.section.type == .chorus })?.section.id
        for slot in slots {
            if slot.hookClusterKey != nil, slot.hookSignatureIndex == 0,
               (slot.hookRepeatIndex ?? 0) > 0, vibe == .hype {
                candidates.append((1, slot.startTime, slot.id))
            }
            guard seenSections.insert(slot.section.id).inserted else { continue }
            if slot.section.type == .drop {
                candidates.append((0, slot.startTime, slot.id))
            } else if slot.section.id == lastChorusID {
                candidates.append((0, slot.startTime, slot.id))
            }
        }

        let tolerance = beatmap.beatDuration * 0.35
        for drop in beatmap.drops.sorted(by: { $0.intensity > $1.intensity }) where drop.intensity >= 0.85 {
            if let slot = slots.min(by: { abs($0.startTime - drop.time) < abs($1.startTime - drop.time) }),
               abs(slot.startTime - drop.time) <= tolerance {
                candidates.append((2, slot.startTime, slot.id))
            }
        }

        var allowed = Set<UUID>()
        for candidate in candidates.sorted(by: {
            $0.priority == $1.priority ? $0.time < $1.time : $0.priority < $1.priority
        }) {
            guard allowed.count < Self.maxFlashCount else { break }
            allowed.insert(candidate.id)
        }
        return allowed
    }

    // MARK: - Transitions

    private func sectionEnergyRank(_ type: SectionType) -> Int {
        switch type {
        case .intro, .outro: return 1
        case .breakdown:     return 2
        case .bridge:        return 3
        case .verse:         return 4
        case .preChorus:     return 5
        case .buildup:       return 6
        case .chorus:        return 7
        case .drop:          return 8
        }
    }

    private func transition(prev: MediaAsset?, prevSection: BeatSection?, prevSlotStart: Double?,
                            next: MediaAsset, slot: TimeSlot,
                            position: Int, isFirstOfSection: Bool,
                            beatmap: Beatmap, vibe: MontageVibe,
                            flashAllowed: Set<UUID>) -> TransitionType {
        if position == 0 { return .fadeFromBlack }

        if slot.isVocalHold { return .crossfade }

        // Flash-white only on budgeted moments — see flashBudgetSlotIDs.
        if flashAllowed.contains(slot.id) { return .flashWhite }

        // Vibe: .nostalgic prefers kenBurnsDrift on section boundaries.
        if vibe == .nostalgic, isFirstOfSection, position > 0 {
            return .kenBurnsDrift
        }

        if isFirstOfSection, let ps = prevSection,
           sectionEnergyRank(ps.type) > sectionEnergyRank(slot.section.type) {
            return .dissolve
        }

        // Whip-pan push between two high-motion clips at peak energy —
        // every third cut so it stays a spice, not a tic.
        if vibe == .hype || vibe == .travel,
           slot.section.type == .chorus || slot.section.type == .drop,
           let p = prev, (p.motionEnergy ?? 0) > 0.55, (next.motionEnergy ?? 0) > 0.55,
           position % 3 == 2 {
            return .whipPan
        }

        // High-energy sections cut hard: a 0.5s crossfade mid-chorus kills
        // the percussive feel, and strong beats deserve a clean hit.
        if slot.section.type == .chorus || slot.section.type == .drop { return .hardCut }
        if isMajorImpact(slot: slot, beatmap: beatmap) { return .hardCut }

        if let pct = prev?.colorTemperature, let nct = next.colorTemperature,
           abs(pct - nct) > 0.4 {
            return .crossfade
        }

        if let ps = prevSection, ps.id == slot.section.id {
            let prevPhrase = prevSlotStart.flatMap { beatmap.phraseStart(before: $0) }
            let currPhrase = beatmap.phraseStart(before: slot.startTime)
            return prevPhrase == currPhrase ? .hardCut : .crossfade
        }

        if let ps = prevSection, ps.id != slot.section.id { return .dissolve }

        return .hardCut
    }

    private func isMajorImpact(slot: TimeSlot, beatmap: Beatmap) -> Bool {
        let tolerance = beatmap.beatDuration * 0.35
        if beatmap.drops.contains(where: { abs($0.time - slot.startTime) <= tolerance && $0.intensity >= 0.75 }) {
            return true
        }
        return beatmap.beatStrength(at: slot.startTime) >= 0.9
    }

    // MARK: - Hero-First Reservation
    // Greedy chronological selection spends the strongest assets on early
    // verse slots before the drop ever gets to ask. An editor lays in the
    // hero moments first and fills around them: priority slots claim assets
    // from the full pool, in order of dramatic importance.

    private func reservePriorityAssets(
        slots: [TimeSlot], pool: [MediaAsset], sectionFirstIDs: Set<UUID>,
        arcIntensities: [UUID: Double], settings: MontageSettings,
        semanticTexts: [String: String], chronoPositions: [String: Double],
        totalDuration: Double
    ) -> [UUID: MediaAsset] {
        var priorities = [(tier: Int, slot: TimeSlot)]()
        for slot in slots {
            guard slot.startTime < totalDuration else { continue }
            let isHero = sectionFirstIDs.contains(slot.id)
                && (slot.section.type == .chorus || slot.section.type == .drop)
            let arc = arcIntensities[slot.section.id] ?? 0.9
            if slot.isAnticipationHold {
                priorities.append((0, slot))
            } else if isHero {
                priorities.append((arc >= 0.95 ? 1 : 2, slot))
            } else if slot.hookClusterKey != nil, (slot.hookRepeatIndex ?? 0) == 0 {
                priorities.append((3, slot))
            } else if slot.isVocalHold || slot.isBreath {
                priorities.append((4, slot))
            }
        }

        var reserved = [UUID: MediaAsset]()
        var used = Set<String>()
        for entry in priorities.sorted(by: {
            $0.tier == $1.tier ? $0.slot.startTime < $1.slot.startTime : $0.tier < $1.tier
        }) {
            let arc = arcIntensities[entry.slot.section.id] ?? 0.9
            guard let picked = selectAsset(
                for: entry.slot, from: pool, used: used, prev: nil,
                arcIntensity: arc, settings: settings, semanticTexts: semanticTexts,
                chronoPositions: chronoPositions,
                slotProgress: entry.slot.startTime / max(totalDuration, 0.01)
            ) else { continue }
            reserved[entry.slot.id] = picked
            used.insert(clipKey(picked))
        }
        return reserved
    }

    // MARK: - Asset Selection

    private func visualEnergy(_ asset: MediaAsset) -> Float {
        let e = asset.emotionScore ?? 0.5
        let n = asset.noveltyScore ?? 0.5
        // Kinetic energy dominates: a jumping/dancing clip should land on a
        // drop even if a posed portrait scores higher on emotion.
        let kinetic = asset.motionEnergy ?? (asset.isVideo ? 0.6 : 0.35)
        return min(1.0, e * 0.40 + n * 0.25 + kinetic * 0.35)
    }

    private func clipKey(_ asset: MediaAsset) -> String {
        "\(asset.id)_\(asset.clipStartTime ?? 0)"
    }

    /// In-point for a video slot. With a motion series, cut on action: the
    /// source's strongest feasible motion moment lands on the slot's peak
    /// beat. Without one, fall back to centering the analyzed best window.
    /// `rate` is the playback speed — a slow-mo slot consumes fewer source
    /// seconds and its peak-beat delta shrinks accordingly.
    static func cutOnActionOffset(asset: MediaAsset, slotStart: Double,
                                  slotDuration: Double, peakBeat: Double,
                                  rate: Double = 1.0) -> TimeInterval {
        guard asset.isVideo else { return 0 }
        let sourceSpan = slotDuration * rate
        let maxOffset = max(0, asset.duration - sourceSpan)
        let delta = max(0, peakBeat - slotStart) * rate   // source seconds until the hit

        if let peakSource = asset.motionPeakTime(in: delta...(maxOffset + delta)) {
            return min(max(0, peakSource - delta), maxOffset)
        }
        let raw = (asset.clipStartTime ?? 0) - delta + sourceSpan * 0.5
        return min(max(0, raw), maxOffset)
    }

    private func minReadableSeconds(for asset: MediaAsset) -> Double {
        switch asset.shotType ?? .medium {
        case .wide:    return 2.0
        case .group:   return 1.5
        case .closeUp: return 1.0
        case .medium:  return 1.0
        case .detail:  return 0.6
        case .motion:  return 0.4
        }
    }

    private func targetEnergy(for slot: TimeSlot, arcIntensity: Double) -> Float {
        let base: Float
        switch slot.section.type {
        case .intro, .outro:  base = 0.25
        case .breakdown:      base = 0.20
        case .bridge:         base = 0.35
        case .verse:          base = 0.45
        case .preChorus:      base = 0.65
        case .buildup:        base = 0.75
        case .chorus:         base = 0.80
        case .drop:           base = 0.90
        }
        return min(1.0, base + Float(arcIntensity - 0.5) * 0.2)
    }

    /// Rank-normalized capture-date positions (0 oldest … 1 newest) so slot
    /// scoring can bias the montage toward chronological progression.
    /// Assets without a creationDate are absent (scored neutral).
    private func chronologyPositions(for pool: [MediaAsset]) -> [String: Double] {
        var dated: [(id: String, date: Date)] = pool.compactMap { asset in
            guard let date = asset.creationDate else { return nil }
            return (id: asset.id, date: date)
        }
        dated.sort { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }
        guard dated.count > 1 else { return dated.isEmpty ? [:] : [dated[0].id: 0.5] }
        let span = Double(dated.count - 1)
        var positions: [String: Double] = [:]
        for (rank, entry) in dated.enumerated() {
            positions[entry.id] = Double(rank) / span
        }
        return positions
    }

    private func scoreAsset(_ a: MediaAsset, for slot: TimeSlot,
                             prev: MediaAsset?, arcIntensity: Double,
                             keywords: [String], semanticTexts: [String: String],
                             chronoPositions: [String: Double], slotProgress: Double) -> Double {
        let isHero      = slot.section.type == .chorus || slot.section.type == .drop
        let target      = targetEnergy(for: slot, arcIntensity: arcIntensity)
        let energy      = visualEnergy(a)
        let energyFit   = 1.0 - Double(abs(energy - target))
        let durationFit: Double = slot.duration >= minReadableSeconds(for: a) + 0.2 ? 1.0 : 0.3
        let heroBonus: Double   = isHero && a.isVideo ? 0.3 : 0.0
        let facesFit: Double    = (isHero && (a.faceAreaFraction ?? 0) > 0) ? 0.2 : 0.0

        let warmthTarget: Double
        switch slot.section.type {
        case .chorus:        warmthTarget = 0.70
        case .drop:          warmthTarget = 0.65
        case .verse, .intro: warmthTarget = 0.35
        case .bridge:        warmthTarget = 0.40
        case .breakdown:     warmthTarget = 0.30
        default:             warmthTarget = 0.50
        }
        let warmthFit = a.colorTemperature.map { 1.0 - min(1.0, abs($0 - warmthTarget) * 2.0) } ?? 0.5

        var noveltyVsPrev = 0.0
        if let p = prev {
            if a.shotType != p.shotType { noveltyVsPrev += 0.15 }
        }

        let isHeroOrPre = isHero || slot.section.type == .preChorus
        let peakFit: Double = (isHeroOrPre && (a.emotionScore ?? 0) > 0.7) ? 0.15 : 0.0
        let semanticFit = semanticFit(a, keywords: keywords, text: semanticTexts[a.id] ?? "")
        let continuityFit = continuityFit(a, prev: prev, slot: slot)
        // Soft chronology: prefer assets whose position in the capture-date
        // timeline matches the slot's position in the song. Strong enough to
        // order similar assets, weak enough for energy/semantic fit to
        // override locally.
        let chronologyFit = chronoPositions[a.id].map { 1.0 - abs($0 - slotProgress) } ?? 0.5

        return 0.24 * energyFit
             + 0.20 * semanticFit
             + 0.10 * durationFit
             + 0.10 * warmthFit
             + 0.11 * continuityFit
             + 0.05 * noveltyVsPrev
             + 0.04 * facesFit
             + 0.03 * peakFit
             + 0.13 * chronologyFit
             + heroBonus
    }

    private func selectAsset(for slot: TimeSlot, from pool: [MediaAsset],
                              used: Set<String>, prev: MediaAsset?, arcIntensity: Double,
                              settings: MontageSettings, semanticTexts: [String: String],
                              chronoPositions: [String: Double], slotProgress: Double) -> MediaAsset? {
        let isHero = slot.section.type == .chorus || slot.section.type == .drop
        let unused = pool.filter { !used.contains(clipKey($0)) }

        if !unused.isEmpty {
            let keywords = semanticKeywords(for: slot, settings: settings)
            let scored = unused.map { ($0, scoreAsset($0, for: slot, prev: prev, arcIntensity: arcIntensity, keywords: keywords, semanticTexts: semanticTexts, chronoPositions: chronoPositions, slotProgress: slotProgress)) }
            if let (best, score) = scored.max(by: { $0.1 < $1.1 }), score > 0.35 {
                return best
            }
            return unused.first
        }

        return isHero ? pool.first : pool.last
    }

    private func semanticFit(_ asset: MediaAsset, keywords target: [String], text: String) -> Double {
        guard !target.isEmpty, !text.isEmpty else { return 0.5 }

        let targetHits = target.reduce(0) { partial, word in
            partial + (text.localizedCaseInsensitiveContains(word) ? 1 : 0)
        }
        let labelHits = (asset.sceneLabels ?? []).reduce(0) { partial, label in
            partial + (target.contains { label.localizedCaseInsensitiveContains($0) } ? 1 : 0)
        }
        let raw = Double(targetHits + labelHits) / Double(max(target.count, 1))
        return min(1.0, 0.35 + raw * 0.75)
    }

    private func continuityFit(_ asset: MediaAsset, prev: MediaAsset?, slot: TimeSlot) -> Double {
        guard let prev else { return 0.65 }
        var score = 0.5
        let calmSection = slot.section.type == .verse || slot.section.type == .intro || slot.section.type == .outro

        if let sim = cosine(asset.semanticEmbedding, prev.semanticEmbedding) {
            let target = calmSection ? 0.62 : 0.42
            score += 0.22 * (1.0 - min(1.0, abs(sim - target)))
        }
        // Visual (FeaturePrint) match-cut: calm sections want related frames,
        // high-energy sections want visual contrast. Near-duplicates (>0.9)
        // read as a stutter, so both targets sit well below that.
        if let vsim = cosine(asset.visualEmbedding, prev.visualEmbedding) {
            let target = calmSection ? 0.55 : 0.30
            score += 0.25 * (1.0 - min(1.0, abs(vsim - target)))
            if vsim > 0.92 { score -= 0.3 }   // jump-cut penalty
        }
        if asset.eventLabel != nil, asset.eventLabel == prev.eventLabel {
            score += 0.1
        }
        if asset.shotType != prev.shotType {
            score += 0.08
        }
        return max(0.0, min(1.0, score))
    }

    private func cosine(_ lhs: [Float]?, _ rhs: [Float]?) -> Double? {
        guard let lhs, let rhs, !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = Float(0)
        var ln = Float(0)
        var rn = Float(0)
        for i in lhs.indices {
            dot += lhs[i] * rhs[i]
            ln += lhs[i] * lhs[i]
            rn += rhs[i] * rhs[i]
        }
        guard ln > 0, rn > 0 else { return nil }
        return Double(dot / sqrt(ln * rn))
    }

    private func semanticText(for asset: MediaAsset) -> String {
        [
            asset.semanticSummary,
            asset.sceneCaption,
            asset.sceneLabels?.joined(separator: " "),
            asset.eventLabel,
            asset.shotType?.rawValue,
            asset.isVideo ? "video" : "photo still"
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    private func semanticKeywords(for slot: TimeSlot, settings: MontageSettings) -> [String] {
        var words: [String] = []
        switch settings.vibe {
        case .nostalgic: words += ["warm", "memory", "family", "golden", "soft", "emotional"]
        case .cinematic: words += ["wide", "dramatic", "landscape", "silhouette", "contrast", "epic"]
        case .hype:      words += ["action", "crowd", "bright", "energy", "fast"]
        case .wholesome: words += ["smile", "family", "friends", "joy", "hug", "warm"]
        case .funny:     words += ["playful", "surprise", "expression", "fun", "party"]
        case .travel:    words += ["travel", "landscape", "city", "road", "water", "mountain", "wide"]
        }

        switch settings.focus {
        case .family:     words += ["family", "child", "parent", "home", "group"]
        case .friends:    words += ["friends", "group", "party", "laugh", "crowd"]
        case .scenery:    words += ["landscape", "sky", "water", "mountain", "city", "wide"]
        case .everything: break
        }

        switch slot.section.type {
        case .intro:     words += ["establishing", "wide", "quiet", "opening"]
        case .verse:     words += ["story", "detail", "face", "place"]
        case .preChorus: words += ["anticipation", "rising", "look", "beauty"]
        case .chorus:    words += ["joy", "hero", "group", "wide", "emotional", "beauty", "bright"]
        case .drop:      words += ["action", "impact", "fast", "video", "party", "beat"]
        case .buildup:   words += ["rising", "detail", "tension"]
        case .bridge:    words += ["reflective", "wide", "quiet", "lonely"]
        case .breakdown: words += ["calm", "still", "texture", "night"]
        case .outro:     words += ["closing", "warm", "memory", "soft"]
        }
        return Array(Set(words))
    }

    // MARK: - Selection Reason

    private func selectionReason(for asset: MediaAsset, slot: TimeSlot,
                                  isHero: Bool, isArcPeak: Bool,
                                  isHookSlot: Bool = false, isHookReturn: Bool = false,
                                  isSlowMotion: Bool = false) -> String {
        var reasons = [String]()
        if let q = asset.qualityScore, q > 0.8  { reasons.append("sharp & well-exposed") }
        if let e = asset.emotionScore, e > 0.75 { reasons.append("strong emotional valence") }
        if let n = asset.noveltyScore, n > 0.7  { reasons.append("visually distinct") }
        if isHero                               { reasons.append("hero hold") }
        if isArcPeak                            { reasons.append("arc peak") }
        if slot.isAnticipationHold              { reasons.append("anticipation hold") }
        if slot.isVocalHold                     { reasons.append("sustained vocal hold") }
        if isSlowMotion                         { reasons.append("slow-motion") }
        if isHookReturn                         { reasons.append("hook return") }
        else if isHookSlot                      { reasons.append("hook signature") }
        if slot.isBreath                        { reasons.append("breath") }
        if asset.isVideo                        { reasons.append("video") }
        if slot.isFlash                         { reasons.append("buildup flash") }
        if slot.beatAligned                     { reasons.append("beat-aligned") }
        if reasons.isEmpty                      { reasons.append("balanced score") }
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
