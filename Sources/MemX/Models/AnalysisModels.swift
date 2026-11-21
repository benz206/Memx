import Foundation

// MARK: - ProcessingPhase

enum ProcessingPhase: String, CaseIterable, Hashable {
    case idle              = "Idle"
    case analyzingAudio    = "Analyzing Audio"
    case scoringPhotos     = "Scoring Photos"
    case sequencing        = "Building Sequence"
    case complete          = "Complete"

    var icon: String {
        switch self {
        case .idle:              return "hourglass"
        case .analyzingAudio:    return "waveform"
        case .scoringPhotos:     return "star.fill"
        case .sequencing:        return "film.stack"
        case .complete:          return "checkmark.circle.fill"
        }
    }

    var index: Int { ProcessingPhase.allCases.firstIndex(of: self) ?? 0 }

    var isWorkPhase: Bool {
        switch self {
        case .analyzingAudio, .scoringPhotos, .sequencing: return true
        case .idle, .complete:                             return false
        }
    }

    var description: String {
        switch self {
        case .idle:              return "Waiting to start"
        case .analyzingAudio:   return "Detecting beats, drops, and energy curve..."
        case .scoringPhotos:     return "Ranking photos by quality, emotion, and novelty..."
        case .sequencing:        return "Snapping cuts to beats and building storyboard..."
        case .complete:          return "Pipeline complete — storyboard ready"
        }
    }
}

// MARK: - PhotoScoringResult

struct PhotoScoringResult {
    var scoredAssets: [MediaAsset]
    var candidates: [ClipCandidate]
}

