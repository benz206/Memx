import Foundation

// MARK: - Project

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var assetIDs: [String]          // PHAsset localIdentifiers
    var settings: MontageSettings
    var status: ProjectStatus
    var songTrack: SongTrack?
    var montagePlan: MontagePlan?
    var exportedVideoURL: URL?

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
    case draft        = "Draft"
    case configuring  = "Configuring"
    case importing    = "Importing"
    case analyzing    = "Analyzing"
    case ready        = "Ready"
    case exported     = "Exported"

    var icon: String {
        switch self {
        case .draft:        return "doc.badge.plus"
        case .configuring:  return "slider.horizontal.3"
        case .importing:    return "arrow.down.circle"
        case .analyzing:    return "cpu"
        case .ready:        return "checkmark.circle.fill"
        case .exported:     return "film.stack"
        }
    }
}

// MARK: - MontageSettings

struct MontageSettings: Codable, Hashable {
    var vibe: MontageVibe
    var focus: MontageFocus
    var aspectRatio: AspectRatio
    var renderQuality: RenderQuality
    var songVolume: Double
    var scoringDensity: ScoringDensity

    init(
        vibe: MontageVibe = .cinematic,
        focus: MontageFocus = .everything,
        aspectRatio: AspectRatio = .widescreen,
        renderQuality: RenderQuality = .parallax2D,
        songVolume: Double = 0.5,
        scoringDensity: ScoringDensity = .balanced
    ) {
        self.vibe = vibe
        self.focus = focus
        self.aspectRatio = aspectRatio
        self.renderQuality = renderQuality
        self.songVolume = songVolume
        self.scoringDensity = scoringDensity
    }

    enum CodingKeys: String, CodingKey {
        case vibe, focus, aspectRatio, renderQuality, songVolume, scoringDensity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vibe = try c.decode(MontageVibe.self, forKey: .vibe)
        self.focus = try c.decode(MontageFocus.self, forKey: .focus)
        self.aspectRatio = try c.decode(AspectRatio.self, forKey: .aspectRatio)
        self.renderQuality = try c.decode(RenderQuality.self, forKey: .renderQuality)
        self.songVolume = try c.decodeIfPresent(Double.self, forKey: .songVolume) ?? 0.5
        self.scoringDensity = try c.decodeIfPresent(ScoringDensity.self, forKey: .scoringDensity) ?? .balanced
    }
}

// MARK: - Enums

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
    case family      = "Family"
    case friends     = "Friends"
    case scenery     = "Scenery"
    case everything  = "Everything"

    var icon: String {
        switch self {
        case .family:     return "house.fill"
        case .friends:    return "person.3.fill"
        case .scenery:    return "mountain.2.fill"
        case .everything: return "sparkles"
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

enum RenderQuality: String, Codable, CaseIterable, Hashable {
    case parallax2D = "2.5D Parallax"
    case hybrid     = "Hybrid"
    case generative = "Generative"

    var description: String {
        switch self {
        case .parallax2D: return "Fast · any Mac · depth-based camera motion"
        case .hybrid:     return "Best moments get generative video · Apple Silicon"
        case .generative: return "Full SVD render · 16GB+ RAM · slowest"
        }
    }

    var icon: String {
        switch self {
        case .parallax2D: return "square.stack.3d.up"
        case .hybrid:     return "sparkles.square.filled.on.square"
        case .generative: return "cpu.fill"
        }
    }
}

enum ScoringDensity: String, Codable, CaseIterable, Hashable {
    case verySparse = "Very Sparse"
    case sparse     = "Sparse"
    case balanced   = "Balanced"
    case dense      = "Dense"
    case veryDense  = "Very Dense"

    /// Target number of frame samples per video when scoring.
    /// OpenRouter analysis uses one representative frame today; the value is
    /// retained for saved settings and future multi-frame sampling.
    var videoFrameSamples: Int {
        switch self {
        case .verySparse: return 8
        case .sparse:     return 14
        case .balanced:   return 20
        case .dense:      return 30
        case .veryDense:  return 48
        }
    }

    var description: String {
        switch self {
        case .verySparse: return "Fastest — may miss peak moments"
        case .sparse:     return "Faster — light sampling"
        case .balanced:   return "Recommended — good quality/speed balance"
        case .dense:      return "Slower — stronger moment selection"
        case .veryDense:  return "Slowest — finest-grained sampling"
        }
    }

    var icon: String {
        switch self {
        case .verySparse: return "hare.fill"
        case .sparse:     return "hare"
        case .balanced:   return "slider.horizontal.3"
        case .dense:      return "tortoise"
        case .veryDense:  return "tortoise.fill"
        }
    }
}
