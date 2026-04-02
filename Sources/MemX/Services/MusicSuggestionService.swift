import Foundation

// MARK: - MusicSuggestionServiceProtocol

protocol MusicSuggestionServiceProtocol {
    func suggestSongs(for settings: MontageSettings, moodArc: [MoodPoint]) async -> [SongSuggestion]
}

// MARK: - MusicSuggestionService (mocked — ready for MusicKit / licensing API)

final class MusicSuggestionService: MusicSuggestionServiceProtocol {

    static let shared = MusicSuggestionService()
    private init() {}

    func suggestSongs(for settings: MontageSettings, moodArc: [MoodPoint]) async -> [SongSuggestion] {
        // TODO: Replace with MusicKit query + mood-vector nearest-neighbor search
        let avgValence = moodArc.map(\.valence).reduce(0, +) / max(1, Double(moodArc.count))
        let avgEnergy  = moodArc.map(\.energy).reduce(0, +) / max(1, Double(moodArc.count))

        try? await Task.sleep(for: .milliseconds(200))

        return catalog
            .filter { compatible(song: $0, genre: settings.musicPreference, vibe: settings.vibe) }
            .map { song in
                var s = song
                // Score by mood proximity
                let tempoNorm = (song.bpm - 60) / 100.0
                let vibeMatch = Float(1.0 - (abs(avgEnergy - tempoNorm) + abs(avgValence - Double(song.energyLevel))) / 2)
                s.vibeMatch = max(0.3, min(1.0, vibeMatch))
                return s
            }
            .sorted { $0.vibeMatch > $1.vibeMatch }
            .prefix(5)
            .map { $0 }
    }

    private func compatible(song: SongSuggestion, genre: MusicGenre, vibe: MontageVibe) -> Bool {
        if genre == .none { return false }
        if genre != song.genre && genre != .ambient { return false }
        switch vibe {
        case .hype:       return song.bpm > 110
        case .nostalgic:  return song.moodTags.contains("warm") || song.moodTags.contains("nostalgic")
        case .cinematic:  return song.moodTags.contains("cinematic") || song.moodTags.contains("epic")
        case .wholesome:  return song.energyLevel < 0.6
        case .funny:      return song.moodTags.contains("playful") || song.bpm > 100
        case .travel:     return song.moodTags.contains("adventure") || song.bpm > 90
        }
    }

    // MARK: - Catalog (mock data for demonstration)

    private var catalog: [SongSuggestion] {[
        SongSuggestion(
            title: "Golden Thread",
            artist: "Novo Amor",
            genre: .indie,
            bpm: 72,
            durationSeconds: 214,
            moodTags: ["warm", "nostalgic", "gentle"],
            vibeMatch: 0.92,
            energyLevel: 0.28
        ),
        SongSuggestion(
            title: "Atlas Hands",
            artist: "Benjamin Francis Leftwich",
            genre: .indie,
            bpm: 68,
            durationSeconds: 248,
            moodTags: ["nostalgic", "soft", "intimate"],
            vibeMatch: 0.88,
            energyLevel: 0.22
        ),
        SongSuggestion(
            title: "Celestial",
            artist: "Ed Sheeran",
            genre: .pop,
            bpm: 78,
            durationSeconds: 230,
            moodTags: ["warm", "uplifting", "wholesome"],
            vibeMatch: 0.81,
            energyLevel: 0.5
        ),
        SongSuggestion(
            title: "Woke Up New",
            artist: "The Mountain Goats",
            genre: .indie,
            bpm: 96,
            durationSeconds: 178,
            moodTags: ["reflective", "nostalgic", "bittersweet"],
            vibeMatch: 0.78,
            energyLevel: 0.45
        ),
        SongSuggestion(
            title: "Drifting",
            artist: "Andy Shauf",
            genre: .ambient,
            bpm: 64,
            durationSeconds: 196,
            moodTags: ["calm", "cinematic", "gentle"],
            vibeMatch: 0.84,
            energyLevel: 0.18
        ),
        SongSuggestion(
            title: "All I Want",
            artist: "Kodaline",
            genre: .indie,
            bpm: 77,
            durationSeconds: 261,
            moodTags: ["emotional", "love", "nostalgic"],
            vibeMatch: 0.9,
            energyLevel: 0.38
        ),
        SongSuggestion(
            title: "Riptide",
            artist: "Vance Joy",
            genre: .indie,
            bpm: 104,
            durationSeconds: 204,
            moodTags: ["playful", "adventure", "upbeat"],
            vibeMatch: 0.76,
            energyLevel: 0.62
        ),
        SongSuggestion(
            title: "Electric Feel",
            artist: "MGMT",
            genre: .electronic,
            bpm: 108,
            durationSeconds: 231,
            moodTags: ["hype", "adventure", "vibrant"],
            vibeMatch: 0.71,
            energyLevel: 0.78
        ),
        SongSuggestion(
            title: "Home",
            artist: "Edward Sharpe",
            genre: .indie,
            bpm: 122,
            durationSeconds: 244,
            moodTags: ["wholesome", "uplifting", "warm"],
            vibeMatch: 0.85,
            energyLevel: 0.68
        ),
        SongSuggestion(
            title: "The Night Will Always Win",
            artist: "Manchester Orchestra",
            genre: .indie,
            bpm: 82,
            durationSeconds: 289,
            moodTags: ["cinematic", "epic", "emotional"],
            vibeMatch: 0.79,
            energyLevel: 0.56
        ),
    ]}
}
