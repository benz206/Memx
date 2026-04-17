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
// Matches photos to beats. High-score photos land on drops and chorus peaks.
// Cut rhythm follows energy: short clips at high energy, long holds at low energy.

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
        let candidates = assets
            .filter { ($0.analysisScore ?? 0) > 0.3 }
            .sorted { ($0.analysisScore ?? 0) > ($1.analysisScore ?? 0) }

        onProgress(0.05, "Filtering \(candidates.count) candidates...")
        logger.info("Sequencer: \(candidates.count) candidates from \(assets.count) assets")

        var sequence: [MontageSequenceItem] = []
        var excludedIDs: [String] = []
        var position = 0
        var currentTime: Double = 0
        let totalDuration = beatmap.durationSeconds

        // Build time slots from beatmap sections
        let timeSlots = buildTimeSlots(from: beatmap)
        onProgress(0.20, "Built \(timeSlots.count) time slots from \(beatmap.sections.count) sections...")
        logger.info("Sequencer: \(timeSlots.count) time slots across \(beatmap.sections.count) sections")

        // Assign candidates to time slots
        var candidatePool = candidates
        let highScoreCandidates = Array(candidatePool.prefix(max(1, candidatePool.count / 4)))
        let remainingCandidates = Array(candidatePool.dropFirst(max(1, candidatePool.count / 4)))
        candidatePool = remainingCandidates + highScoreCandidates // high score goes last → reserved for hero slots

        var usedAssetIDs: [String] = []
        let totalSlots = timeSlots.count

        for (slotIndex, slot) in timeSlots.enumerated() {
            guard currentTime < totalDuration else { break }

            if slotIndex % max(1, totalSlots / 10) == 0 {
                let slotProgress = Double(slotIndex + 1) / Double(max(totalSlots, 1))
                onProgress(0.20 + slotProgress * 0.70, "Placing clip \(position + 1) of ~\(totalSlots)...")
            }

            // Pick best available asset for this slot's energy level
            let isHeroSlot = slot.section.type == .drop || slot.section.type == .chorus
            let asset: MediaAsset?
            if isHeroSlot {
                // Use highest-score unused asset
                asset = candidates.first { !usedAssetIDs.contains($0.id) }
            } else {
                // Pick next sequential (chronological after scoring)
                asset = candidatePool.first { !usedAssetIDs.contains($0.id) }
            }

            guard let selectedAsset = asset else { continue }
            usedAssetIDs.append(selectedAsset.id)

            let prompt = promptMap[selectedAsset.id]
            let energy = Float(beatmap.energy(at: slot.startTime))
            let transIn = transitionIn(for: slot.section.type, position: position)
            let transOut = transitionOut(for: slot.section.type)

            let item = MontageSequenceItem(
                position: position,
                assetID: selectedAsset.id,
                startTime: slot.startTime,
                endTime: min(slot.endTime, totalDuration),
                transitionIn: transIn,
                transitionOut: transOut,
                motionPrompt: prompt?.prompt ?? "",
                motionIntensity: prompt?.motionIntensity ?? energy,
                beatAligned: slot.beatAligned,
                confidenceScore: selectedAsset.analysisScore ?? 0.7,
                sectionType: slot.section.type,
                selectionReason: selectionReason(for: selectedAsset, slot: slot),
                clipOffset: selectedAsset.clipStartTime ?? 0
            )
            sequence.append(item)
            currentTime = slot.endTime
            position += 1
        }

        onProgress(0.95, "Finalizing \(sequence.count) clips...")
        logger.info("Sequencer: assigned \(sequence.count) clips")

        // Track excluded assets
        let usedSet = Set(usedAssetIDs)
        excludedIDs = candidates.filter { !usedSet.contains($0.id) }.map(\.id)

        // Build mood arc from energy curve
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
    }

    private func buildTimeSlots(from beatmap: Beatmap) -> [TimeSlot] {
        var slots: [TimeSlot] = []

        for section in beatmap.sections {
            let clipRange = section.type.clipHoldSeconds
            let clipDuration = Double.random(in: clipRange)
            var t = section.start

            while t + clipDuration <= section.end {
                // Snap to nearest beat
                let snappedStart = beatmap.nearestBeat(to: t)
                let snappedEnd = min(beatmap.nearestBeat(to: t + clipDuration), section.end)
                guard snappedEnd > snappedStart else { t += clipDuration; continue }

                slots.append(TimeSlot(
                    startTime: snappedStart,
                    endTime: snappedEnd,
                    section: section,
                    beatAligned: true
                ))
                t = snappedEnd
            }
        }
        return slots
    }

    // MARK: - Transition Selection

    private func transitionIn(for section: SectionType, position: Int) -> TransitionType {
        if position == 0 { return .fadeFromBlack }
        switch section {
        case .drop:           return .flashWhite
        case .buildup:        return .crossfade
        case .breakdown, .bridge: return .dissolve
        case .intro, .outro:  return .dissolve
        default:              return Bool.random() ? .hardCut : .crossfade
        }
    }

    private func transitionOut(for section: SectionType) -> TransitionType {
        switch section {
        case .drop:           return .hardCut
        case .outro:          return .dissolve
        case .breakdown:      return .crossfade
        default:              return .hardCut
        }
    }

    // MARK: - Selection Reason

    private func selectionReason(for asset: MediaAsset, slot: TimeSlot) -> String {
        var reasons: [String] = []
        if let q = asset.qualityScore, q > 0.8 { reasons.append("sharp & well-exposed") }
        if let e = asset.emotionScore, e > 0.75 { reasons.append("strong emotional valence") }
        if let n = asset.noveltyScore, n > 0.7 { reasons.append("visually distinct") }
        if slot.section.type == .drop || slot.section.type == .chorus { reasons.append("hero slot") }
        if slot.beatAligned { reasons.append("beat-aligned") }
        if reasons.isEmpty { reasons.append("balanced score") }
        return reasons.joined(separator: " · ")
    }

    // MARK: - Mood Arc

    private func buildMoodArc(from beatmap: Beatmap, sequence: [MontageSequenceItem]) -> [MoodPoint] {
        guard !beatmap.energyCurve.isEmpty else { return [] }
        let total = beatmap.durationSeconds
        return beatmap.energyCurve.compactMap { point in
            guard total > 0 else { return nil }
            let valence = 0.4 + point.energy * 0.6  // energy → approximate valence
            return MoodPoint(
                position: point.time / total,
                valence: valence,
                energy: point.energy,
                label: beatmap.section(at: point.time)?.type.rawValue ?? ""
            )
        }
    }
}
