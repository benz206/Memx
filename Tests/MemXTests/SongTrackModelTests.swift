import XCTest
@testable import MemXCore

final class SongTrackModelTests: XCTestCase {

    private let testURL = URL(fileURLWithPath: "/mock/test.mp3")

    // MARK: - durationString

    func testDurationStringZeroSeconds() {
        let track = SongTrack(title: "T", fileURL: testURL, durationSeconds: 0)
        XCTAssertEqual(track.durationString, "0:00")
    }

    func testDurationStringUnderOneMinute() {
        let track = SongTrack(title: "T", fileURL: testURL, durationSeconds: 45)
        XCTAssertEqual(track.durationString, "0:45")
    }

    func testDurationStringSingleDigitSeconds() {
        let track = SongTrack(title: "T", fileURL: testURL, durationSeconds: 65)
        XCTAssertEqual(track.durationString, "1:05")
    }

    func testDurationStringLongerTrack() {
        let track = SongTrack(title: "T", fileURL: testURL, durationSeconds: 214)
        XCTAssertEqual(track.durationString, "3:34")
    }

    func testDurationStringExactMinutes() {
        let track = SongTrack(title: "T", fileURL: testURL, durationSeconds: 120)
        XCTAssertEqual(track.durationString, "2:00")
    }

    // MARK: - displayTitle / displayArtist

    func testDisplayTitleReturnsTitle() {
        let track = SongTrack(title: "Golden Thread", fileURL: testURL)
        XCTAssertEqual(track.displayTitle, "Golden Thread")
    }

    func testDisplayArtistReturnsArtistWhenSet() {
        let track = SongTrack(title: "T", artist: "Novo Amor", fileURL: testURL)
        XCTAssertEqual(track.displayArtist, "Novo Amor")
    }

    func testDisplayArtistFallsBackToUnknown() {
        let track = SongTrack(title: "T", artist: nil, fileURL: testURL)
        XCTAssertEqual(track.displayArtist, "Unknown Artist")
    }

    // MARK: - fileFormatIcon

    func testMP3Icon() {
        let track = SongTrack(title: "T", fileURL: testURL, fileFormat: "mp3")
        XCTAssertEqual(track.fileFormatIcon, "music.note")
    }

    func testM4AIcon() {
        let track = SongTrack(title: "T", fileURL: testURL, fileFormat: "m4a")
        XCTAssertEqual(track.fileFormatIcon, "music.note")
    }

    func testWAVIcon() {
        let track = SongTrack(title: "T", fileURL: testURL, fileFormat: "wav")
        XCTAssertEqual(track.fileFormatIcon, "waveform")
    }

    func testAACIcon() {
        let track = SongTrack(title: "T", fileURL: testURL, fileFormat: "aac")
        XCTAssertEqual(track.fileFormatIcon, "headphones")
    }

    func testUnknownFormatFallbackIcon() {
        let track = SongTrack(title: "T", fileURL: testURL, fileFormat: "ogg")
        XCTAssertEqual(track.fileFormatIcon, "music.note.list")
    }

    func testCaseInsensitiveFormat() {
        let track = SongTrack(title: "T", fileURL: testURL, fileFormat: "MP3")
        XCTAssertEqual(track.fileFormatIcon, "music.note")
    }

    // MARK: - init defaults

    func testDefaultFileFormat() {
        let track = SongTrack(title: "T", fileURL: testURL)
        XCTAssertEqual(track.fileFormat, "mp3")
    }

    func testDefaultDuration() {
        let track = SongTrack(title: "T", fileURL: testURL)
        XCTAssertEqual(track.durationSeconds, 0, accuracy: 0.001)
    }

    func testNilBPMByDefault() {
        let track = SongTrack(title: "T", fileURL: testURL)
        XCTAssertNil(track.bpm)
    }

    // MARK: - Codable

    func testSongTrackCodableRoundTrip() throws {
        let track = SongTrack(
            title: "Riptide",
            artist: "Vance Joy",
            fileURL: testURL,
            durationSeconds: 204,
            fileFormat: "mp3"
        )
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(SongTrack.self, from: data)
        XCTAssertEqual(decoded.id, track.id)
        XCTAssertEqual(decoded.title, "Riptide")
        XCTAssertEqual(decoded.artist, "Vance Joy")
        XCTAssertEqual(decoded.durationSeconds, 204, accuracy: 0.001)
        XCTAssertEqual(decoded.fileFormat, "mp3")
    }
}
