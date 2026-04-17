import Foundation

// MARK: - MontagePlan

struct MontagePlan: Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var totalDuration: TimeInterval     // matches song duration
    var sequence: [MontageSequenceItem]
    var moodArc: [MoodPoint]
    var excludedAssetIDs: [String]
    var settings: MontageSettings

    init(
        id: UUID = UUID(),
        title: String,
        settings: MontageSettings,
        sequence: [MontageSequenceItem] = [],
        moodArc: [MoodPoint] = [],
        excludedAssetIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.settings = settings
        self.sequence = sequence
        self.moodArc = moodArc
        self.excludedAssetIDs = excludedAssetIDs
        self.totalDuration = sequence.last?.endTime ?? 0
    }
}

// MARK: - MontageSequenceItem

struct MontageSequenceItem: Identifiable, Codable, Hashable {
    let id: UUID
    var position: Int
    var assetID: String
    var startTime: TimeInterval         // position in the song timeline
    var endTime: TimeInterval
    var transitionIn: TransitionType
    var transitionOut: TransitionType
    var motionPrompt: String
    var motionIntensity: Float          // 0.0 – 1.0
    var beatAligned: Bool
    var confidenceScore: Float
    var sectionType: SectionType?       // which song section this clip lands in
    var selectionReason: String
    var clipOffset: TimeInterval        // start offset within source video (0 for photos)

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        position: Int,
        assetID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        transitionIn: TransitionType = .crossfade,
        transitionOut: TransitionType = .hardCut,
        motionPrompt: String = "",
        motionIntensity: Float = 0.5,
        beatAligned: Bool = false,
        confidenceScore: Float = 0.8,
        sectionType: SectionType? = nil,
        selectionReason: String = "",
        clipOffset: TimeInterval = 0
    ) {
        self.id = id
        self.position = position
        self.assetID = assetID
        self.startTime = startTime
        self.endTime = endTime
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.motionPrompt = motionPrompt
        self.motionIntensity = motionIntensity
        self.beatAligned = beatAligned
        self.confidenceScore = confidenceScore
        self.sectionType = sectionType
        self.selectionReason = selectionReason
        self.clipOffset = clipOffset
    }
}

// MARK: - TransitionType

enum TransitionType: String, Codable, CaseIterable, Hashable {
    case fadeFromBlack = "Fade from Black"
    case crossfade     = "Crossfade"
    case hardCut       = "Hard Cut"
    case flashWhite    = "Flash White"
    case whipPan       = "Whip Pan"
    case dissolve      = "Dissolve"
    case kenBurnsDrift = "Ken Burns"

    var defaultDuration: TimeInterval {
        switch self {
        case .fadeFromBlack: return 0.8
        case .crossfade:     return 0.5
        case .hardCut:       return 0
        case .flashWhite:    return 0.15
        case .whipPan:       return 0.25
        case .dissolve:      return 0.6
        case .kenBurnsDrift: return 1.2
        }
    }

    var icon: String {
        switch self {
        case .fadeFromBlack: return "moon.fill"
        case .crossfade:     return "circle.dotted"
        case .hardCut:       return "scissors"
        case .flashWhite:    return "bolt.fill"
        case .whipPan:       return "arrow.right"
        case .dissolve:      return "drop.fill"
        case .kenBurnsDrift: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

// MARK: - MoodPoint (for energy curve visualization)

struct MoodPoint: Codable, Hashable {
    var position: Double    // 0.0 – 1.0 through the montage
    var valence: Double     // 0.0 (sad) – 1.0 (joyful)
    var energy: Double      // 0.0 (calm) – 1.0 (intense)
    var label: String
}

// MARK: - ClipCandidate (photo scoring stage)

struct ClipCandidate: Identifiable, Hashable {
    let id: UUID
    let assetID: String
    var overallScore: Float
    var qualityScore: Float
    var emotionScore: Float
    var noveltyScore: Float
    var faces: Int
    var rejectionReason: String?
    var isIncluded: Bool

    init(
        id: UUID = UUID(),
        assetID: String,
        overallScore: Float,
        qualityScore: Float = 0.8,
        emotionScore: Float = 0.7,
        noveltyScore: Float = 0.6,
        faces: Int = 0,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.assetID = assetID
        self.overallScore = overallScore
        self.qualityScore = qualityScore
        self.emotionScore = emotionScore
        self.noveltyScore = noveltyScore
        self.faces = faces
        self.isIncluded = isIncluded
    }
}
