import Foundation

// MARK: - AnalysisJobStatus

struct AnalysisJobStatus: Identifiable, Hashable {
    let id: UUID
    var projectID: UUID
    var phase: AnalysisPhase
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
        self.message = "Ready to analyze"
        self.startedAt = Date()
    }
}

// MARK: - AnalysisPhase

enum AnalysisPhase: String, CaseIterable, Hashable {
    case idle             = "Idle"
    case loadingAssets    = "Loading Assets"
    case detectingScenes  = "Detecting Scenes"
    case extractingEmb    = "Extracting Embeddings"
    case clusteringEvents = "Clustering Events"
    case scoringMoments   = "Scoring Moments"
    case selectingSong    = "Selecting Soundtrack"
    case buildingStoryboard = "Building Storyboard"
    case complete         = "Complete"

    var icon: String {
        switch self {
        case .idle:              return "hourglass"
        case .loadingAssets:     return "photo.stack"
        case .detectingScenes:   return "eye.fill"
        case .extractingEmb:     return "waveform.path.ecg"
        case .clusteringEvents:  return "circle.hexagongrid.fill"
        case .scoringMoments:    return "star.fill"
        case .selectingSong:     return "music.note"
        case .buildingStoryboard: return "film.stack"
        case .complete:          return "checkmark.circle.fill"
        }
    }

    var index: Int { AnalysisPhase.allCases.firstIndex(of: self) ?? 0 }
    var totalPhases: Int { AnalysisPhase.allCases.count - 2 } // exclude idle+complete

    var description: String {
        switch self {
        case .idle:              return "Waiting to start"
        case .loadingAssets:     return "Fetching assets from Photos library..."
        case .detectingScenes:   return "Analyzing scene boundaries and composition..."
        case .extractingEmb:     return "Running vision model embeddings on-device..."
        case .clusteringEvents:  return "Grouping similar moments into events..."
        case .scoringMoments:    return "Ranking clips by emotion, quality & novelty..."
        case .selectingSong:     return "Matching mood profile to soundtrack candidates..."
        case .buildingStoryboard: return "Assembling optimal sequence with beat alignment..."
        case .complete:          return "Analysis complete — storyboard ready"
        }
    }
}

// MARK: - MemoryEvent

struct MemoryEvent: Identifiable, Hashable {
    let id: UUID
    var label: String
    var description: String
    var assetIDs: [String]
    var startDate: Date?
    var endDate: Date?
    var location: String?
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

    var color: String {
        switch self {
        case .joy:        return "yellow"
        case .nostalgia:  return "orange"
        case .excitement: return "red"
        case .calm:       return "blue"
        case .awe:        return "purple"
        case .humor:      return "green"
        case .love:       return "pink"
        case .surprise:   return "teal"
        }
    }

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

// MARK: - SceneSegment (granular analysis result)

struct SceneSegment: Identifiable, Hashable {
    let id: UUID
    let assetID: String
    var segmentStart: TimeInterval
    var segmentEnd: TimeInterval
    var sceneLabel: String          // e.g. "outdoor · golden hour · group"
    var embedding: [Float]?         // TODO: connect to real on-device ML model
    var qualityScore: Float
    var blurScore: Float            // 0 = sharp, 1 = blurry
    var exposureScore: Float        // 0 = under/over, 1 = perfect
    var compositionScore: Float
    var detectedObjects: [String]
    var detectedText: String?
    var transcriptSnippet: String?  // for video segments

    init(
        id: UUID = UUID(),
        assetID: String,
        segmentStart: TimeInterval = 0,
        segmentEnd: TimeInterval = 0,
        sceneLabel: String,
        qualityScore: Float = 0.8,
        detectedObjects: [String] = []
    ) {
        self.id = id
        self.assetID = assetID
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
        self.sceneLabel = sceneLabel
        self.qualityScore = qualityScore
        self.blurScore = Float.random(in: 0...0.3)
        self.exposureScore = Float.random(in: 0.6...1.0)
        self.compositionScore = Float.random(in: 0.5...1.0)
        self.detectedObjects = detectedObjects
    }
}
