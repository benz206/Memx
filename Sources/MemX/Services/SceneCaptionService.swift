import CoreGraphics
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "scene-caption")

protocol SceneCaptionServiceProtocol {
    func caption(for cgImage: CGImage, sceneLabels: [String]) async -> String?
}

final class SceneCaptionService: SceneCaptionServiceProtocol {

    static let shared = SceneCaptionService()
    private init() {}

    private static let instructions: String = """
        You write short, evocative captions for photos used in a music-video montage. \
        One sentence, 8 to 15 words, present tense, no preamble. Describe what's happening \
        or the feeling. Do not wrap the sentence in quotes. Do not use emoji or special characters.
        """

    func caption(for cgImage: CGImage, sceneLabels: [String]) async -> String? {
        let cleanLabels = sceneLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        logger.info("caption requested: \(cleanLabels.count) scene labels")

        var userPrompt = "Caption this photo."
        if !cleanLabels.isEmpty {
            userPrompt += " Hint tags from a separate scene classifier: \(cleanLabels.joined(separator: ", "))."
        }

        logger.debug("VLM invoke — prompt: \(userPrompt, privacy: .public)")
        let start = Date()
        let result = await LocalVLMService.shared.describe(
            image: cgImage,
            instructions: Self.instructions,
            prompt: userPrompt,
            maxTokens: 60
        )
        let elapsed = Date().timeIntervalSince(start)
        if let caption = result {
            logger.info(
                "caption ok in \(elapsed, format: .fixed(precision: 2))s (\(caption.count) chars): \(caption, privacy: .public)"
            )
        } else {
            logger.warning("caption nil after \(elapsed, format: .fixed(precision: 2))s")
        }
        return result
    }
}
