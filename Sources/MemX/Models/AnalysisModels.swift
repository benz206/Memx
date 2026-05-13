import Foundation

// MARK: - ProcessingStatus

struct ProcessingStatus: Identifiable, Hashable {
    let id: UUID
    var projectID: UUID
    var phase: ProcessingPhase
    var progress: Double        // 0.0 – 1.0
    var message: String
    var startedAt: Date
    var completedAt: Date?
    var error: String?

    var isComplete: Bool { phase == .complete }
    var isFailed: Bool { error != nil }

    init(projectID: UUID) {
        self.id = UUID()
        self.projectID = projectID
        self.phase = .idle
        self.progress = 0
        self.message = "Ready"
        self.startedAt = Date()
    }
}

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

// MARK: - MemoryEvent (kept for optional grouping display)

struct MemoryEvent: Identifiable, Hashable {
    let id: UUID
    var label: String
    var description: String
    var assetIDs: [String]
    var startDate: Date?
    var endDate: Date?
    var dominantEmotion: Emotion
    var importanceScore: Float
    var representativeAssetID: String?

    init(
        id: UUID = UUID(),
        label: String,
        description: String,
        assetIDs: [String] = [],
        dominantEmotion: Emotion = .joy,
        importanceScore: Float = 0.7
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.assetIDs = assetIDs
        self.dominantEmotion = dominantEmotion
        self.importanceScore = importanceScore
    }
}

// MARK: - Emotion

enum Emotion: String, Codable, CaseIterable, Hashable {
    case joy        = "Joy"
    case nostalgia  = "Nostalgia"
    case excitement = "Excitement"
    case calm       = "Calm"
    case awe        = "Awe"
    case humor      = "Humor"
    case love       = "Love"
    case surprise   = "Surprise"

    var icon: String {
        switch self {
        case .joy:        return "sun.max.fill"
        case .nostalgia:  return "clock.arrow.circlepath"
        case .excitement: return "bolt.fill"
        case .calm:       return "leaf.fill"
        case .awe:        return "sparkles"
        case .humor:      return "face.smiling.fill"
        case .love:       return "heart.fill"
        case .surprise:   return "exclamationmark.circle.fill"
        }
    }
}
