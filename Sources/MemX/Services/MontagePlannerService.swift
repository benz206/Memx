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
// Musical-arc cut planner: per-section beat patterns, dramatic arc intensity scaling,
// scored asset selection, motion-matched transitions, peak-aligned clip offsets,
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
        motionPrompts: [MotionPrompt],
        beatmap: Beatmap,
        onProgress: @escaping (Double, String) -> Void
    ) async -> MontagePlan {

        let promptMap = Dictionary(uniqueKeysWithValues: motionPrompts.map { ($0.assetID, $0) })

        let scored           = assets.filter { ($0.analysisScore ?? 0) > 0.3 }
        let candidates       = scored.sorted { visualEnergy($0) > visualEnergy($1) }
        let fallbackCandidates = assets.sorted { visualEnergy($0) > visualEnergy($1) }

        onProgress(0.05, "Filtering \(candidates.count) candidates...")
        logger.info("Sequencer: \(candidates.count) candidates from \(assets.count) assets")

        let beatDur        = beatmap.beatDuration
        let barStarts      = beatmap.barStarts(beatsPerBar: 4)
        let arcIntensities = buildArcIntensities(sections: beatmap.sections)

        var timeSlots = buildTimeSlots(from: beatmap, beatDur: beatDur,
                                       barStarts: barStarts, arcIntensities: arcIntensities)
        applyBreathShots(to: &timeSlots, beatmap: beatmap, beatDur: beatDur)

        onProgress(0.20, "Built \(timeSlots.count) time slots from \(beatmap.sections.count) sections...")
        logger.info("Sequencer: \(timeSlots.count) time slots across \(beatmap.sections.count) sections")

        let pool          = candidates.isEmpty ? fallbackCandidates : candidates
        var usedKeys      = Set<String>()
        var sequence      = [MontageSequenceItem]()
        let totalDuration = beatmap.durationSeconds
        var position      = 0
        var prevAsset: MediaAsset?   = nil
        var prevSection: BeatSection? = nil
        var prevSlotStart: Double?   = nil

        let sectionFirstIDs = buildSectionFirstSlotIDs(from: timeSlots)
        let totalSlots      = timeSlots.count

        for (slotIndex, slot) in timeSlots.enumerated() {
            guard slot.startTime < totalDuration else { break }

            if slotIndex % max(1, totalSlots / 10) == 0 {
                let prog = Double(slotIndex + 1) / Double(max(totalSlots, 1))
                onProgress(0.20 + prog * 0.70, "Placing clip \(position + 1) of ~\(totalSlots)...")
            }

            let arcIntensity = arcIntensities[slot.section.id] ?? 0.9
            guard let asset = selectAsset(for: slot, from: pool, used: usedKeys,
                                          prev: prevAsset, arcIntensity: arcIntensity) else { continue }
            usedKeys.insert(clipKey(asset))

            let prompt  = promptMap[asset.id]
            let energy  = Float(beatmap.energy(at: slot.startTime))
            let isFirst = sectionFirstIDs.contains(slot.id)
            let isHero  = isFirst && (slot.section.type == .chorus || slot.section.type == .drop)

            let trans = transition(prev: prevAsset, prevSection: prevSection,
                                   prevSlotStart: prevSlotStart, next: asset,
                                   slot: slot, position: position,
                                   isFirstOfSection: isFirst, beatmap: beatmap)

            let microOffset = (position > 0 && !isHero
                               && trans != .fadeFromBlack && trans != .dissolve) ? 0.04 : 0.0

            let itemStart = max(0, slot.startTime - microOffset)
            let itemEnd   = min(max(0, slot.endTime - microOffset), totalDuration)

            let peakBeat = slot.peakBeat ?? slot.startTime
            let clipOffset: TimeInterval
            if asset.isVideo {
                let raw = (asset.clipStartTime ?? 0) - (peakBeat - slot.startTime) + slot.duration * 0.5
                clipOffset = min(max(0, raw), max(0, asset.duration - slot.duration))
            } else {
                clipOffset = 0
            }

            let isMatchCut = trans == .hardCut
                             && prevAsset?.motionVector != nil && asset.motionVector != nil
            let isArcPeak  = isHero && arcIntensity >= 0.95

            let item = MontageSequenceItem(
                position: position,
                assetID: asset.id,
                startTime: itemStart,
                endTime: itemEnd,
                transitionIn: trans,
                transitionOut: .hardCut,
                motionPrompt: prompt?.prompt ?? "",
                motionIntensity: prompt?.motionIntensity ?? energy,
                beatAligned: slot.beatAligned,
                confidenceScore: asset.analysisScore ?? 0.7,
                sectionType: slot.section.type,
                selectionReason: selectionReason(for: asset, slot: slot,
                                                  isHero: isHero,
                                                  isMatchCut: isMatchCut,
                                                  isArcPeak: isArcPeak),
                clipOffset: clipOffset,
                peakTime: peakBeat
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
        var duration: Double { endTime - startTime }

        init(startTime: Double, endTime: Double, section: BeatSection,
             beatAligned: Bool, isFlash: Bool = false,
             peakBeat: Double? = nil, isBreath: Bool = false) {
            self.id          = UUID()
            self.startTime   = startTime
            self.endTime     = endTime
            self.section     = section
            self.beatAligned = beatAligned
            self.isFlash     = isFlash
            self.peakBeat    = peakBeat
            self.isBreath    = isBreath
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

    private func baseCutPattern(for type: SectionType, leadsToDrop: Bool) -> CutPattern {
        switch type {
        case .intro:
            return CutPattern(durationsInBeats: [8, 8, 4, 8],              isAnchoredToBar: true)
        case .verse:
            return CutPattern(durationsInBeats: [4, 4, 2, 2, 4],           isAnchoredToBar: true)
        case .preChorus:
            return CutPattern(durationsInBeats: [4, 2, 2, 1, 1],           isAnchoredToBar: true)
        case .chorus:
            return CutPattern(durationsInBeats: [8, 4, 4, 2, 2, 4],        isAnchoredToBar: true)
        case .drop:
            return CutPattern(durationsInBeats: [8, 4, 2, 2, 1, 1, 2, 4],  isAnchoredToBar: true)
        case .breakdown:
            return CutPattern(durationsInBeats: [16],                       isAnchoredToBar: true)
        case .bridge:
            return CutPattern(durationsInBeats: [8, 8, 16],                 isAnchoredToBar: true)
        case .outro:
            return CutPattern(durationsInBeats: [8, 16, 32],                isAnchoredToBar: true)
        case .buildup:
            let durs: [Double] = leadsToDrop
                ? [4, 4, 2, 2, 1, 1, 0.5, 0.5, 0.25, 0.25]
                : [4, 2, 2, 1]
            return CutPattern(durationsInBeats: durs, isAnchoredToBar: leadsToDrop)
        }
    }

    private func adjustedPattern(base: CutPattern, sectionType: SectionType,
                                  arcIntensity: Double,
                                  encounterIndex k: Int, totalEncounters n: Int,
                                  sectionBeatCount: Int, leadsToDrop: Bool) -> CutPattern {
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

        // Soft version: slow down fast tail for low-intensity sections
        if arcIntensity < 0.8 {
            durs = durs.map { $0 <= 2.0 ? $0 * 2.0 : $0 }
        }

        // Hero hold length scales with encounter position
        if (sectionType == .chorus || sectionType == .drop) && !durs.isEmpty {
            durs[0] = (k == n - 1 && n > 1) ? 16.0 : 8.0
            if arcIntensity >= 0.95 {
                durs.insert(8.0, at: 0)
            }
        }

        return CutPattern(durationsInBeats: durs, isAnchoredToBar: base.isAnchoredToBar)
    }

    // MARK: - Time Slot Building

    private func buildTimeSlots(from beatmap: Beatmap, beatDur: Double,
                                 barStarts: [Double], arcIntensities: [UUID: Double]) -> [TimeSlot] {
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
            let base    = baseCutPattern(for: section.type, leadsToDrop: leadsToDrop)
            let pattern = adjustedPattern(base: base, sectionType: section.type,
                                          arcIntensity: arcIntensity,
                                          encounterIndex: k, totalEncounters: n,
                                          sectionBeatCount: sectionBeats.count,
                                          leadsToDrop: leadsToDrop)

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

            let nearStart   = beatmap.nearestBeat(to: t)
            let actualStart = abs(nearStart - t) <= 0.5 * beatDur ? nearStart : t

            let nearEnd     = beatmap.nearestBeat(to: computedEnd)
            let snappedEnd  = abs(nearEnd - computedEnd) <= 0.5 * beatDur ? nearEnd : computedEnd
            let actualEnd   = min(snappedEnd, section.end)

            guard actualEnd > actualStart + 0.01 else { t = rawEnd; continue }

            let dur      = actualEnd - actualStart
            let isFlash  = dur < beatDur
            let aligned  = abs(nearStart - t) <= 0.5 * beatDur
            let peakBeat = beatmap.strongestBeat(in: actualStart...actualEnd)

            slots.append(TimeSlot(startTime: actualStart, endTime: actualEnd,
                                  section: section, beatAligned: aligned,
                                  isFlash: isFlash, peakBeat: peakBeat))
            t = rawEnd
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
                            beatmap: Beatmap) -> TransitionType {
        if position == 0 { return .fadeFromBlack }

        if isFirstOfSection && slot.section.type == .drop { return .flashWhite }

        if isFirstOfSection, let ps = prevSection,
           sectionEnergyRank(ps.type) > sectionEnergyRank(slot.section.type) {
            return .dissolve
        }

        if let pmv = prev?.motionVector, let nmv = next.motionVector,
           abs(pmv.dx - nmv.dx) < 0.3 && abs(pmv.dy - nmv.dy) < 0.3
           && pmv.magnitude > 0.2 && nmv.magnitude > 0.2 {
            return .hardCut
        }

        if next.shotType == .motion || (next.motionVector?.magnitude ?? 0) > 0.6 {
            return .whipPan
        }

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

    // MARK: - Asset Selection

    private func visualEnergy(_ asset: MediaAsset) -> Float {
        let e          = asset.emotionScore ?? 0.5
        let n          = asset.noveltyScore ?? 0.5
        let videoBoost: Float = asset.isVideo ? 0.1 : 0
        return min(1.0, e * 0.6 + n * 0.4 + videoBoost)
    }

    private func clipKey(_ asset: MediaAsset) -> String {
        "\(asset.id)_\(asset.clipStartTime ?? 0)"
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

    private func scoreAsset(_ a: MediaAsset, for slot: TimeSlot,
                             prev: MediaAsset?, arcIntensity: Double) -> Double {
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
        let warmthFit = a.colorTemperature.map { 1.0 - abs($0 - warmthTarget) } ?? 0.5

        var noveltyVsPrev = 0.0
        if let p = prev {
            if a.shotType != p.shotType { noveltyVsPrev += 0.15 }
            if let amv = a.motionVector, let pmv = p.motionVector,
               abs(amv.magnitude - pmv.magnitude) > 0.4 { noveltyVsPrev += 0.1 }
        }

        let isHeroOrPre = isHero || slot.section.type == .preChorus
        let peakFit: Double = (isHeroOrPre && (a.emotionScore ?? 0) > 0.7) ? 0.15 : 0.0

        return 0.30 * energyFit
             + 0.20 * durationFit
             + 0.15 * warmthFit
             + 0.15 * noveltyVsPrev
             + 0.10 * facesFit
             + 0.10 * peakFit
             + heroBonus
    }

    private func selectAsset(for slot: TimeSlot, from pool: [MediaAsset],
                              used: Set<String>, prev: MediaAsset?, arcIntensity: Double) -> MediaAsset? {
        let isHero = slot.section.type == .chorus || slot.section.type == .drop
        let unused = pool.filter { !used.contains(clipKey($0)) }

        if !unused.isEmpty {
            let scored = unused.map { ($0, scoreAsset($0, for: slot, prev: prev, arcIntensity: arcIntensity)) }
            if let (best, score) = scored.max(by: { $0.1 < $1.1 }), score > 0.35 {
                return best
            }
            return unused.first
        }

        return isHero ? pool.first : pool.last
    }

    // MARK: - Selection Reason

    private func selectionReason(for asset: MediaAsset, slot: TimeSlot,
                                  isHero: Bool, isMatchCut: Bool, isArcPeak: Bool) -> String {
        var reasons = [String]()
        if let q = asset.qualityScore, q > 0.8  { reasons.append("sharp & well-exposed") }
        if let e = asset.emotionScore, e > 0.75 { reasons.append("strong emotional valence") }
        if let n = asset.noveltyScore, n > 0.7  { reasons.append("visually distinct") }
        if isHero                               { reasons.append("hero hold") }
        if isArcPeak                            { reasons.append("arc peak") }
        if isMatchCut                           { reasons.append("match cut") }
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
