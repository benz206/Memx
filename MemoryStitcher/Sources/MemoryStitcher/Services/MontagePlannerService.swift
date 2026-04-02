import Foundation

// MARK: - MontagePlannerServiceProtocol

protocol MontagePlannerServiceProtocol {
    func buildPlan(
        title: String,
        settings: MontageSettings,
        analysisResult: AnalysisResult
    ) async -> MontagePlan
}

// MARK: - MontagePlannerService

final class MontagePlannerService: MontagePlannerServiceProtocol {

    static let shared = MontagePlannerService()
    private let musicService = MusicSuggestionService.shared
    private init() {}

    func buildPlan(
        title: String,
        settings: MontageSettings,
        analysisResult: AnalysisResult
    ) async -> MontagePlan {

        let targetDuration = settings.targetDuration.seconds
        let candidates = analysisResult.candidates
            .filter(\.isIncluded)
            .sorted { $0.overallScore > $1.overallScore }

        // Select clips that fit within target duration
        var sequence: [MontageSequenceItem] = []
        var usedDuration: TimeInterval = 0
        var position = 0
        var currentTime: TimeInterval = 0

        // Determine clip budget
        let avgClipDuration = clipDuration(for: settings.pacing)
        let maxClips = Int(targetDuration / avgClipDuration)

        // Order by event for narrative flow
        let orderedCandidates = orderByNarrativeFlow(
            candidates: candidates,
            events: analysisResult.events,
            maxClips: maxClips,
            assets: analysisResult.scoredAssets
        )

        for candidate in orderedCandidates {
            guard usedDuration < targetDuration else { break }
            let asset = analysisResult.scoredAssets.first(where: { $0.id == candidate.assetID })
            let clipDur = candidateClipDuration(candidate: candidate, settings: settings)
            let transition = selectTransition(for: position, settings: settings, candidate: candidate)
            let event = analysisResult.events.first(where: { $0.assetIDs.contains(candidate.assetID) })
            let reason = selectionReason(for: candidate, event: event)

            let item = MontageSequenceItem(
                position: position,
                assetID: candidate.assetID,
                clipStart: candidate.clipStart,
                clipEnd: candidate.clipStart + clipDur,
                transitionType: transition,
                eventLabel: event?.label ?? "General",
                selectionReason: reason,
                beatAligned: Bool.random(),
                confidenceScore: candidate.overallScore,
                estimatedFinalStart: currentTime,
                estimatedFinalEnd: currentTime + clipDur
            )
            sequence.append(item)
            usedDuration += clipDur
            currentTime += clipDur + transition.defaultDuration
            position += 1
        }

        // Mood arc
        let moodArc = buildMoodArc(from: analysisResult.events, sequence: sequence)

        // Songs
        let songs = await musicService.suggestSongs(for: settings, moodArc: moodArc)

        var plan = MontagePlan(
            title: title,
            settings: settings,
            sequence: sequence,
            suggestedSongs: songs,
            moodArc: moodArc
        )
        plan.eventSummary = summarizeEvents(analysisResult.events)
        plan.totalDuration = sequence.reduce(0) { $0 + $1.clipDuration }
        return plan
    }

    // MARK: - Helpers

    private func clipDuration(for pacing: MontagePacing) -> TimeInterval {
        switch pacing {
        case .slow:      return 4.5
        case .balanced:  return 2.8
        case .energetic: return 1.6
        }
    }

    private func candidateClipDuration(candidate: ClipCandidate, settings: MontageSettings) -> TimeInterval {
        let base = clipDuration(for: settings.pacing)
        if candidate.overallScore > 0.85 {
            return base * 1.4  // Let great shots breathe
        } else if candidate.overallScore < 0.55 {
            return base * 0.7  // Trim weaker shots
        }
        return base
    }

    private func selectTransition(for position: Int, settings: MontageSettings, candidate: ClipCandidate) -> TransitionType {
        switch settings.pacing {
        case .energetic:
            return [.cut, .flash, .cut, .cut].randomElement()!
        case .slow:
            return [.crossDissolve, .dip, .crossDissolve].randomElement()!
        case .balanced:
            if position == 0 { return .dip }
            return [.cut, .crossDissolve, .cut, .swipe].randomElement()!
        }
    }

    private func orderByNarrativeFlow(
        candidates: [ClipCandidate],
        events: [MemoryEvent],
        maxClips: Int,
        assets: [MediaAsset]
    ) -> [ClipCandidate] {
        // Group candidates by event, pick top N from each, then interleave for arc
        var byEvent: [String: [ClipCandidate]] = [:]
        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

        for candidate in candidates {
            let eventLabel = assetMap[candidate.assetID]?.eventLabel ?? "General"
            byEvent[eventLabel, default: []].append(candidate)
        }

        // Keep top 3 from each event, ordered by events
        var ordered: [ClipCandidate] = []
        for event in events {
            let eventCandidates = (byEvent[event.label] ?? [])
                .sorted { $0.overallScore > $1.overallScore }
                .prefix(3)
            ordered.append(contentsOf: eventCandidates)
        }

        // Fill remaining slots
        let usedIDs = Set(ordered.map(\.assetID))
        let remaining = candidates.filter { !usedIDs.contains($0.assetID) }
        ordered.append(contentsOf: remaining)

        return Array(ordered.prefix(maxClips))
    }

    private func selectionReason(for candidate: ClipCandidate, event: MemoryEvent?) -> String {
        var reasons: [String] = []

        if candidate.qualityScore > 0.8 { reasons.append("sharp & well-exposed") }
        if candidate.emotionScore > 0.75 { reasons.append("strong emotional valence") }
        if candidate.noveltyScore > 0.7 { reasons.append("visually distinct from neighbors") }
        if candidate.faces > 0 { reasons.append("\(candidate.faces) face\(candidate.faces > 1 ? "s" : "") detected") }
        if candidate.motionScore > 0.7 { reasons.append("dynamic motion") }

        if reasons.isEmpty { reasons.append("balanced score across quality metrics") }
        return reasons.joined(separator: " · ")
    }

    private func buildMoodArc(from events: [MemoryEvent], sequence: [MontageSequenceItem]) -> [MoodPoint] {
        guard !sequence.isEmpty else { return [] }
        let totalDur = sequence.last.map { $0.estimatedFinalEnd } ?? 1

        return sequence.enumerated().compactMap { idx, item in
            let position = totalDur > 0 ? item.estimatedFinalStart / totalDur : Double(idx) / Double(sequence.count)
            let event = events.first(where: { $0.assetIDs.contains(item.assetID) })
            let (valence, energy) = moodForEmotion(event?.dominantEmotion ?? .joy)
            return MoodPoint(
                position: position,
                valence: valence,
                energy: energy,
                label: event?.label ?? "Scene \(idx + 1)"
            )
        }
    }

    private func moodForEmotion(_ emotion: Emotion) -> (Double, Double) {
        switch emotion {
        case .joy:        return (0.9, 0.7)
        case .nostalgia:  return (0.6, 0.3)
        case .excitement: return (0.8, 0.95)
        case .calm:       return (0.5, 0.2)
        case .awe:        return (0.75, 0.5)
        case .humor:      return (0.85, 0.6)
        case .love:       return (0.95, 0.4)
        case .surprise:   return (0.7, 0.8)
        }
    }

    private func summarizeEvents(_ events: [MemoryEvent]) -> String {
        let labels = events.map(\.label)
        if labels.isEmpty { return "A personal montage" }
        if labels.count == 1 { return labels[0] }
        return labels.dropLast().joined(separator: ", ") + " & " + labels.last!
    }
}
