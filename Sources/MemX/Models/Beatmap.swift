import Foundation

// MARK: - Beatmap

struct Beatmap: Codable, Hashable {
    var bpm: Double
    var durationSeconds: TimeInterval
    var energyCurve: [EnergyPoint]
    var sections: [BeatSection]
    var beats: [Double]
    var drops: [BeatMoment]
    var vocalPeaks: [BeatMoment]
    var phraseStarts: [Double] = []
    var beatStrengths: [Double] = []
    var hooks: [HookMoment] = []

    var beatDuration: Double { 60.0 / max(bpm, 1) }

    func hook(at time: Double) -> HookMoment? {
        hooks.first { $0.startTime <= time && time < $0.endTime }
    }

    var finalHookStart: Double? { hooks.map(\.startTime).max() }

    func barStarts(beatsPerBar: Int = 4) -> [Double] {
        stride(from: 0, to: beats.count, by: beatsPerBar).map { beats[$0] }
    }

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

    func phraseStart(before time: Double) -> Double? {
        phraseStarts.filter { $0 <= time }.max()
    }

    func phraseStart(after time: Double) -> Double? {
        phraseStarts.filter { $0 > time }.min()
    }

    func beatStrength(at time: Double) -> Double {
        guard !beats.isEmpty,
              let idx = beats.indices.min(by: { abs(beats[$0] - time) < abs(beats[$1] - time) })
        else { return 0.35 }
        return strengthFor(index: idx)
    }

    func strongestBeat(in range: ClosedRange<Double>) -> Double? {
        let candidates = beats.enumerated().filter { range.contains($0.element) }
        guard !candidates.isEmpty else { return nil }
        return candidates.max(by: { a, b in
            let sa = strengthFor(index: a.offset)
            let sb = strengthFor(index: b.offset)
            if sa != sb { return sa < sb }
            return a.element > b.element
        })?.element
    }

    private func strengthFor(index i: Int) -> Double {
        if !beatStrengths.isEmpty, beatStrengths.indices.contains(i) {
            return beatStrengths[i]
        }
        return synthesizedStrength(beatIndex: i)
    }

    private func synthesizedStrength(beatIndex i: Int) -> Double {
        let pos = i % 4
        let base: Double = pos == 0 ? 0.75 : pos == 2 ? 0.5 : 0.35
        let beatTime = i < beats.count ? beats[i] : Double(i) * beatDuration
        let half = beatDuration * 0.5
        return phraseStarts.contains(where: { abs($0 - beatTime) < half }) ? 1.0 : base
    }
}

// MARK: - Beatmap Codable

extension Beatmap {
    private enum CodingKeys: String, CodingKey {
        case bpm, durationSeconds, energyCurve, sections, beats, drops, vocalPeaks
        case phraseStarts, beatStrengths, hooks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
        energyCurve = try c.decode([EnergyPoint].self, forKey: .energyCurve)
        sections = try c.decode([BeatSection].self, forKey: .sections)
        beats = try c.decode([Double].self, forKey: .beats)
        drops = try c.decode([BeatMoment].self, forKey: .drops)
        vocalPeaks = try c.decode([BeatMoment].self, forKey: .vocalPeaks)
        phraseStarts = try c.decodeIfPresent([Double].self, forKey: .phraseStarts) ?? []
        beatStrengths = try c.decodeIfPresent([Double].self, forKey: .beatStrengths) ?? []
        hooks = try c.decodeIfPresent([HookMoment].self, forKey: .hooks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(energyCurve, forKey: .energyCurve)
        try c.encode(sections, forKey: .sections)
        try c.encode(beats, forKey: .beats)
        try c.encode(drops, forKey: .drops)
        try c.encode(vocalPeaks, forKey: .vocalPeaks)
        try c.encode(phraseStarts, forKey: .phraseStarts)
        try c.encode(beatStrengths, forKey: .beatStrengths)
        try c.encode(hooks, forKey: .hooks)
    }
}

// MARK: - HookMoment

struct HookMoment: Codable, Hashable {
    var startTime: Double
    var endTime: Double
    var repeatIndex: Int            // 0 for first encounter, 1 for second, etc.
    var signatureBeats: [Double]    // strongest accented beats inside the hook window
    var similarity: Double          // 0.0–1.0 cosine similarity to the prototype
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

    var duration: Double { end - start }

    init(
        id: UUID = UUID(),
        type: SectionType,
        start: Double,
        end: Double,
        energyAvg: Double
    ) {
        self.id = id
        self.type = type
        self.start = start
        self.end = end
        self.energyAvg = energyAvg
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
