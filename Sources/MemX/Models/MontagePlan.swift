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
    var motionIntensity: Float          // 0.0 – 1.0
    var beatAligned: Bool
    var confidenceScore: Float
    var sectionType: SectionType?       // which song section this clip lands in
    var selectionReason: String
    var clipOffset: TimeInterval        // start offset within source video (0 for photos)
    var peakTime: TimeInterval?
    var isHookMoment: Bool = false          // the slot lands inside a detected hook
    var isAnticipationHold: Bool = false    // the slot is the pre-final-chorus hold
    var hookRepeatIndex: Int? = nil         // 0 = first time, 1 = second, ...
    var gradingHint: GradingHint? = nil     // passthrough for future color grading
    var speedFactor: Double = 1.0           // video playback rate (0.75 = slow-mo hold)

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        position: Int,
        assetID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        transitionIn: TransitionType = .crossfade,
        transitionOut: TransitionType = .hardCut,
        motionIntensity: Float = 0.5,
        beatAligned: Bool = false,
        confidenceScore: Float = 0.8,
        sectionType: SectionType? = nil,
        selectionReason: String = "",
        clipOffset: TimeInterval = 0,
        peakTime: TimeInterval? = nil,
        isHookMoment: Bool = false,
        isAnticipationHold: Bool = false,
        hookRepeatIndex: Int? = nil,
        gradingHint: GradingHint? = nil,
        speedFactor: Double = 1.0
    ) {
        self.id = id
        self.position = position
        self.assetID = assetID
        self.startTime = startTime
        self.endTime = endTime
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.motionIntensity = motionIntensity
        self.beatAligned = beatAligned
        self.confidenceScore = confidenceScore
        self.sectionType = sectionType
        self.selectionReason = selectionReason
        self.clipOffset = clipOffset
        self.peakTime = peakTime
        self.isHookMoment = isHookMoment
        self.isAnticipationHold = isAnticipationHold
        self.hookRepeatIndex = hookRepeatIndex
        self.gradingHint = gradingHint
        self.speedFactor = speedFactor
    }

    // MARK: - Codable (decodeIfPresent for new fields so legacy plans still decode)

    private enum CodingKeys: String, CodingKey {
        case id, position, assetID, startTime, endTime
        case transitionIn, transitionOut
        case motionIntensity
        case beatAligned, confidenceScore
        case sectionType, selectionReason
        case clipOffset, peakTime
        case isHookMoment, isAnticipationHold, hookRepeatIndex, gradingHint
        case speedFactor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        position = try c.decode(Int.self, forKey: .position)
        assetID = try c.decode(String.self, forKey: .assetID)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        transitionIn = try c.decode(TransitionType.self, forKey: .transitionIn)
        transitionOut = try c.decode(TransitionType.self, forKey: .transitionOut)
        motionIntensity = try c.decode(Float.self, forKey: .motionIntensity)
        beatAligned = try c.decode(Bool.self, forKey: .beatAligned)
        confidenceScore = try c.decode(Float.self, forKey: .confidenceScore)
        sectionType = try c.decodeIfPresent(SectionType.self, forKey: .sectionType)
        selectionReason = try c.decode(String.self, forKey: .selectionReason)
        clipOffset = try c.decode(TimeInterval.self, forKey: .clipOffset)
        peakTime = try c.decodeIfPresent(TimeInterval.self, forKey: .peakTime)
        isHookMoment = try c.decodeIfPresent(Bool.self, forKey: .isHookMoment) ?? false
        isAnticipationHold = try c.decodeIfPresent(Bool.self, forKey: .isAnticipationHold) ?? false
        hookRepeatIndex = try c.decodeIfPresent(Int.self, forKey: .hookRepeatIndex)
        gradingHint = try c.decodeIfPresent(GradingHint.self, forKey: .gradingHint)
        speedFactor = try c.decodeIfPresent(Double.self, forKey: .speedFactor) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(position, forKey: .position)
        try c.encode(assetID, forKey: .assetID)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(transitionIn, forKey: .transitionIn)
        try c.encode(transitionOut, forKey: .transitionOut)
        try c.encode(motionIntensity, forKey: .motionIntensity)
        try c.encode(beatAligned, forKey: .beatAligned)
        try c.encode(confidenceScore, forKey: .confidenceScore)
        try c.encodeIfPresent(sectionType, forKey: .sectionType)
        try c.encode(selectionReason, forKey: .selectionReason)
        try c.encode(clipOffset, forKey: .clipOffset)
        try c.encodeIfPresent(peakTime, forKey: .peakTime)
        try c.encode(isHookMoment, forKey: .isHookMoment)
        try c.encode(isAnticipationHold, forKey: .isAnticipationHold)
        try c.encodeIfPresent(hookRepeatIndex, forKey: .hookRepeatIndex)
        try c.encodeIfPresent(gradingHint, forKey: .gradingHint)
        try c.encode(speedFactor, forKey: .speedFactor)
    }
}

// MARK: - GradingHint

enum GradingHint: String, Codable, CaseIterable, Hashable {
    case warm, cool, desaturated, contrasty, golden, nostalgic
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
