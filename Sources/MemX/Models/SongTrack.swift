import Foundation

// MARK: - SongTrack

struct SongTrack: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String?
    var fileURL: URL
    var durationSeconds: TimeInterval
    var fileFormat: String          // "mp3", "m4a", "wav", "aac"
    var bpm: Double?                // filled after beatmap analysis

    init(
        id: UUID = UUID(),
        title: String,
        artist: String? = nil,
        fileURL: URL,
        durationSeconds: TimeInterval = 0,
        fileFormat: String = "mp3"
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.fileFormat = fileFormat
    }

    var displayTitle: String { title }
    var displayArtist: String { artist ?? "Unknown Artist" }

    var durationString: String {
        let m = Int(durationSeconds) / 60
        let s = Int(durationSeconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    var fileFormatIcon: String {
        switch fileFormat.lowercased() {
        case "mp3":  return "music.note"
        case "m4a":  return "music.note"
        case "wav":  return "waveform"
        case "aac":  return "headphones"
        default:     return "music.note.list"
        }
    }
}
