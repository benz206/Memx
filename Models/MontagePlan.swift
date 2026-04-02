import Foundation

// MARK: - MontagePlan

struct MontagePlan: Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var totalDuration: TimeInterval
    var sequence: [MontageSequenceItem]
    var suggestedSongs: [SongSuggestion]
    var moodArc: [MoodPoint]
    var eventSummary: String
    var settings: MontageSettings

    init(
        id: UUID = UUID(),
        title: String,
        settings: MontageSettings,
        sequence: [MontageSequenceItem] = [],
        suggestedSongs: [SongSuggestion] = [],
        moodArc: [MoodPoint] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.settings = settings
        self.sequence = sequence
        self.suggestedSongs = suggestedSongs
        self.moodArc = moodArc
        self.totalDuration = sequence.reduce(0) { $0 + $1.clipDuration }
        self.eventSummary = ""
    }
}

// MARK: - MontageSequenceItem

struct MontageSequenceItem: Identifiable, Codable, Hashable {
    let id: UUID
    var position: Int
    var assetID: String
    var clipStart: TimeInterval
    var clipEnd: TimeInterval
    var clipDuration: TimeInterval
    var transitionType: TransitionType
    var transitionDuration: TimeInterval
    var eventLabel: String
    var selectionReason: String
    var beatAligned: Bool
    var confidenceScore: Float
    var estimatedFinalStart: TimeInterval   // position in the output timeline
    var estimatedFinalEnd: TimeInterval

    init(
        id: UUID = UUID(),
        position: Int,
        assetID: String,
        clipStart: TimeInterval = 0,
        clipEnd: TimeInterval,
        transitionType: TransitionType = .cut,
        eventLabel: String,
        selectionReason: String,
        beatAligned: Bool = false,
        confidenceScore: Float = 0.8,
        estimatedFinalStart: TimeInterval = 0,
        estimatedFinalEnd: TimeInterval = 0
    ) {
        self.id = id
        self.position = position
        self.assetID = assetID
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.clipDuration = clipEnd - clipStart
        self.transitionType = transitionType
        self.transitionDuration = transitionType.defaultDuration
        self.eventLabel = eventLabel
        self.selectionReason = selectionReason
        self.beatAligned = beatAligned
        self.confidenceScore = confidenceScore
        self.estimatedFinalStart = estimatedFinalStart
        self.estimatedFinalEnd = estimatedFinalEnd
    }
}

// MARK: - TransitionType

enum TransitionType: String, Codable, CaseIterable, Hashable {
    case cut       = "Cut"
    case crossDissolve = "Cross Dissolve"
    case dip       = "Dip to Black"
    case swipe     = "Swipe"
    case zoom      = "Zoom Burst"
    case flash     = "Flash"
    case none      = "None"

    var defaultDuration: TimeInterval {
        switch self {
        case .cut:          return 0
        case .crossDissolve: return 0.5
        case .dip:          return 0.7
        case .swipe:        return 0.4
        case .zoom:         return 0.3
        case .flash:        return 0.2
        case .none:         return 0
        }
    }

    var icon: String {
        switch self {
        case .cut:          return "scissors"
        case .crossDissolve: return "circle.dotted"
        case .dip:          return "moon.fill"
        case .swipe:        return "arrow.right"
        case .zoom:         return "arrow.up.left.and.arrow.down.right"
        case .flash:        return "bolt.fill"
        case .none:         return "minus"
        }
    }
}

// MARK: - SongSuggestion

struct SongSuggestion: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var genre: MusicGenre
    var bpm: Double
    var durationSeconds: TimeInterval
    var moodTags: [String]
    var vibeMatch: Float
    var energyLevel: Float
    var previewURL: String?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        genre: MusicGenre,
        bpm: Double,
        durationSeconds: TimeInterval,
        moodTags: [String] = [],
        vibeMatch: Float = 0.8,
        energyLevel: Float = 0.5,
        previewURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.genre = genre
        self.bpm = bpm
        self.durationSeconds = durationSeconds
        self.moodTags = moodTags
        self.vibeMatch = vibeMatch
        self.energyLevel = energyLevel
        self.previewURL = previewURL
    }
}

// MARK: - MoodPoint (for mood arc visualization)

struct MoodPoint: Codable, Hashable {
    var position: Double    // 0.0 – 1.0 through the montage
    var valence: Double     // 0.0 (sad) – 1.0 (joyful)
    var energy: Double      // 0.0 (calm) – 1.0 (intense)
    var label: String
}

// MARK: - ClipCandidate (pre-selection stage)

struct ClipCandidate: Identifiable, Hashable {
    let id: UUID
    let assetID: String
    var clipStart: TimeInterval
    var clipEnd: TimeInterval
    var overallScore: Float
    var qualityScore: Float
    var emotionScore: Float
    var noveltyScore: Float
    var motionScore: Float
    var faces: Int
    var rejectionReason: String?
    var isIncluded: Bool

    init(
        id: UUID = UUID(),
        assetID: String,
        clipStart: TimeInterval = 0,
        clipEnd: TimeInterval,
        overallScore: Float,
        qualityScore: Float = 0.8,
        emotionScore: Float = 0.7,
        noveltyScore: Float = 0.6,
        motionScore: Float = 0.5,
        faces: Int = 0,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.assetID = assetID
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.overallScore = overallScore
        self.qualityScore = qualityScore
        self.emotionScore = emotionScore
        self.noveltyScore = noveltyScore
        self.motionScore = motionScore
        self.faces = faces
        self.isIncluded = isIncluded
    }
}
