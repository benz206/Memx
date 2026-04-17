import Foundation

// MARK: - Beatmap

struct Beatmap: Codable, Hashable {
    var bpm: Double
    var durationSeconds: TimeInterval
    var energyCurve: [EnergyPoint]
    var sections: [BeatSection]
    var beats: [Double]             // timestamps in seconds
    var drops: [BeatMoment]
    var vocalPeaks: [BeatMoment]

    /// Nearest beat timestamp to a given time
    func nearestBeat(to time: Double) -> Double {
        beats.min(by: { abs($0 - time) < abs($1 - time) }) ?? time
    }

    func section(at time: Double) -> BeatSection? {
        sections.first { $0.start <= time && time < $0.end }
    }

    func energy(at time: Double) -> Double {
        let sorted = energyCurve.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return 0.5 }
        for i in 0..<sorted.count - 1 {
            let a = sorted[i], b = sorted[i + 1]
            if time >= a.time && time <= b.time {
                let t = (time - a.time) / max(b.time - a.time, 0.001)
                return a.energy + t * (b.energy - a.energy)
            }
        }
        return sorted.last?.energy ?? 0.5
    }
}

// MARK: - EnergyPoint

struct EnergyPoint: Codable, Hashable {
    var time: Double
    var energy: Double  // 0.0 – 1.0
}

// MARK: - BeatSection

struct BeatSection: Identifiable, Codable, Hashable {
    let id: UUID
    var type: SectionType
    var start: Double
    var end: Double
    var energyAvg: Double
    var cutStyle: CutStyle

    var duration: Double { end - start }

    init(
        id: UUID = UUID(),
        type: SectionType,
        start: Double,
        end: Double,
        energyAvg: Double,
        cutStyle: CutStyle
    ) {
        self.id = id
        self.type = type
        self.start = start
        self.end = end
        self.energyAvg = energyAvg
        self.cutStyle = cutStyle
    }
}

// MARK: - BeatMoment

struct BeatMoment: Codable, Hashable {
    var time: Double
    var intensity: Double  // 0.0 – 1.0
}

// MARK: - SectionType

enum SectionType: String, Codable, CaseIterable, Hashable {
    case intro     = "Intro"
    case verse     = "Verse"
    case preChorus = "Pre-Chorus"
    case chorus    = "Chorus"
    case buildup   = "Buildup"
    case drop      = "Drop"
    case bridge    = "Bridge"
    case breakdown = "Breakdown"
    case outro     = "Outro"

    var icon: String {
        switch self {
        case .intro, .outro:  return "arrow.right.circle"
        case .verse:          return "music.note"
        case .preChorus:      return "arrow.up.circle"
        case .chorus:         return "star.circle.fill"
        case .buildup:        return "chart.line.uptrend.xyaxis"
        case .drop:           return "bolt.circle.fill"
        case .bridge:         return "arrow.triangle.swap"
        case .breakdown:      return "waveform.path"
        }
    }

    var accentColor: String {
        switch self {
        case .intro, .outro:  return "gray"
        case .verse:          return "blue"
        case .preChorus:      return "teal"
        case .chorus:         return "indigo"
        case .buildup:        return "orange"
        case .drop:           return "red"
        case .bridge:         return "purple"
        case .breakdown:      return "mint"
        }
    }

    /// Typical clip hold duration for this section type (seconds)
    var clipHoldSeconds: ClosedRange<Double> {
        switch self {
        case .intro, .outro:  return 3.0...6.0
        case .verse:          return 2.0...4.0
        case .preChorus:      return 1.5...3.0
        case .chorus:         return 1.0...2.5
        case .buildup:        return 0.8...2.0
        case .drop:           return 0.3...1.5
        case .bridge:         return 4.0...8.0
        case .breakdown:      return 6.0...12.0
        }
    }
}

// MARK: - CutStyle

enum CutStyle: String, Codable, Hashable {
    case slowFade       = "Slow Fade"
    case onBeat         = "On Beat"
    case accelerating   = "Accelerating"
    case rapidCut       = "Rapid Cut"
    case singleHold     = "Single Hold"
    case kenBurnsDrift  = "Ken Burns"
}
