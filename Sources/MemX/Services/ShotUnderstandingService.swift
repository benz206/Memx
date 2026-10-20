import CoreGraphics
import Foundation
import FoundationModels
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "understanding")

struct ShotUnderstanding: Hashable {
    var caption: String
    var mood: String
    var subjects: [String]
    var emotion: Float
    var energy: Float
    var highlight: Float

    var summary: String {
        ([mood] + subjects).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@Generable
struct ShotLog {
    @Guide(description: "One concrete sentence describing who or what is in the shot and what is happening")
    var caption: String
    @Guide(description: "The dominant mood of the moment", .anyOf(["joyful", "tender", "calm", "nostalgic", "energetic", "dramatic", "playful", "awe"]))
    var mood: String
    @Guide(description: "Up to four main subjects as short nouns, e.g. friends, dog, beach, birthday cake", .maximumCount(4))
    var subjects: [String]
    @Guide(description: "How emotionally charged the moment is: 0 nothing personal, 10 a peak life moment", .range(0...10))
    var emotion: Int
    @Guide(description: "Physical energy or action in the frame: 0 completely still, 10 explosive motion", .range(0...10))
    var energy: Int
    @Guide(description: "How strong this shot is as a hero moment on a music drop: 0 filler, 10 unforgettable", .range(0...10))
    var highlight: Int
}

enum ShotUnderstandingService {

    static var isAvailable: Bool {
        guard #available(macOS 27.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func understand(_ image: CGImage, labels: [String], faceCount: Int) async -> ShotUnderstanding? {
        guard #available(macOS 27.0, *), isAvailable else { return nil }

        let hints = labels.isEmpty ? "none" : labels.prefix(6).joined(separator: ", ")
        let session = LanguageModelSession(instructions: """
            You are a music-video editor logging personal photos and video frames for a montage. \
            Describe only what is visible. Be specific and concise.
            """)
        do {
            let response = try await session.respond(
                generating: ShotLog.self,
                options: GenerationOptions(samplingMode: .greedy)
            ) {
                "Log this shot. Detector hints (may be wrong): \(hints). Faces detected: \(faceCount)."
                Attachment(image)
            }
            return map(response.content)
        } catch {
            logger.info("Shot understanding skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func map(_ log: ShotLog) -> ShotUnderstanding {
        ShotUnderstanding(
            caption: log.caption.trimmingCharacters(in: .whitespacesAndNewlines),
            mood: log.mood,
            subjects: log.subjects.map { $0.lowercased() },
            emotion: unit(log.emotion),
            energy: unit(log.energy),
            highlight: unit(log.highlight)
        )
    }

    private static func unit(_ v: Int) -> Float { Float(min(10, max(0, v))) / 10 }
}
