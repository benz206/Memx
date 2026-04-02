import Foundation

// MARK: - Project

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var assetIDs: [String]           // PHAsset localIdentifiers
    var settings: MontageSettings
    var status: ProjectStatus
    var montagePlan: MontagePlan?
    var analysisJobID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        settings: MontageSettings = MontageSettings()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.assetIDs = []
        self.settings = settings
        self.status = .draft
    }
}

// MARK: - ProjectStatus

enum ProjectStatus: String, Codable, CaseIterable {
    case draft       = "Draft"
    case importing   = "Importing"
    case analyzing   = "Analyzing"
    case ready       = "Ready"
    case exported    = "Exported"

    var icon: String {
        switch self {
        case .draft:     return "doc.badge.plus"
        case .importing: return "arrow.down.circle"
        case .analyzing: return "cpu"
        case .ready:     return "checkmark.circle.fill"
        case .exported:  return "film.stack"
        }
    }

    var color: String {
        switch self {
        case .draft:     return "secondary"
        case .importing: return "blue"
        case .analyzing: return "orange"
        case .ready:     return "green"
        case .exported:  return "purple"
        }
    }
}

// MARK: - MontageSettings

struct MontageSettings: Codable, Hashable {
    var targetDuration: TargetDuration
    var vibe: MontageVibe
    var focus: MontageFocus
    var pacing: MontagePacing
    var aspectRatio: AspectRatio
    var musicPreference: MusicGenre

    init(
        targetDuration: TargetDuration = .sixty,
        vibe: MontageVibe = .cinematic,
        focus: MontageFocus = .everything,
        pacing: MontagePacing = .balanced,
        aspectRatio: AspectRatio = .widescreen,
        musicPreference: MusicGenre = .ambient
    ) {
        self.targetDuration = targetDuration
        self.vibe = vibe
        self.focus = focus
        self.pacing = pacing
        self.aspectRatio = aspectRatio
        self.musicPreference = musicPreference
    }
}

// MARK: - Enums

enum TargetDuration: String, Codable, CaseIterable, Hashable {
    case thirty    = "30s"
    case sixty     = "60s"
    case ninety    = "90s"
    case twoMinutes = "2min"
    case custom    = "Custom"

    var seconds: Double {
        switch self {
        case .thirty:     return 30
        case .sixty:      return 60
        case .ninety:     return 90
        case .twoMinutes: return 120
        case .custom:     return 60
        }
    }

    var label: String { rawValue }
}

enum MontageVibe: String, Codable, CaseIterable, Hashable {
    case nostalgic  = "Nostalgic"
    case cinematic  = "Cinematic"
    case hype       = "Hype"
    case wholesome  = "Wholesome"
    case funny      = "Funny"
    case travel     = "Travel"

    var icon: String {
        switch self {
        case .nostalgic:  return "clock.arrow.circlepath"
        case .cinematic:  return "film"
        case .hype:       return "bolt.fill"
        case .wholesome:  return "heart.fill"
        case .funny:      return "face.smiling"
        case .travel:     return "airplane"
        }
    }

    var description: String {
        switch self {
        case .nostalgic:  return "Warm, reflective, golden-toned"
        case .cinematic:  return "Epic, dramatic, widescreen"
        case .hype:       return "Fast-cut, high-energy, punchy"
        case .wholesome:  return "Gentle, joyful, heartfelt"
        case .funny:      return "Playful, comedic, unexpected"
        case .travel:     return "Adventurous, wide, exploratory"
        }
    }
}

enum MontageFocus: String, Codable, CaseIterable, Hashable {
    case family   = "Family"
    case friends  = "Friends"
    case scenery  = "Scenery"
    case everything = "Everything"

    var icon: String {
        switch self {
        case .family:     return "house.fill"
        case .friends:    return "person.3.fill"
        case .scenery:    return "mountain.2.fill"
        case .everything: return "sparkles"
        }
    }
}

enum MontagePacing: String, Codable, CaseIterable, Hashable {
    case slow       = "Slow"
    case balanced   = "Balanced"
    case energetic  = "Energetic"

    var beatsPerMinute: ClosedRange<Double> {
        switch self {
        case .slow:      return 60...90
        case .balanced:  return 90...120
        case .energetic: return 120...160
        }
    }
}

enum AspectRatio: String, Codable, CaseIterable, Hashable {
    case portrait   = "9:16"
    case widescreen = "16:9"
    case square     = "1:1"

    var cgRatio: Double {
        switch self {
        case .portrait:   return 9.0 / 16.0
        case .widescreen: return 16.0 / 9.0
        case .square:     return 1.0
        }
    }
}

enum MusicGenre: String, Codable, CaseIterable, Hashable {
    case ambient     = "Ambient"
    case indie       = "Indie"
    case electronic  = "Electronic"
    case classical   = "Classical"
    case hiphop      = "Hip-Hop"
    case pop         = "Pop"
    case none        = "No Music"

    var icon: String {
        switch self {
        case .ambient:    return "waveform"
        case .indie:      return "guitars"
        case .electronic: return "headphones"
        case .classical:  return "music.note"
        case .hiphop:     return "beats.headphones"
        case .pop:        return "star.fill"
        case .none:       return "speaker.slash.fill"
        }
    }
}
