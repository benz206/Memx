import Foundation
import CoreGraphics
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.memx.app", category: "scene-caption")

// MARK: - SceneCaptionServiceProtocol

protocol SceneCaptionServiceProtocol {
    func caption(for cgImage: CGImage, sceneLabels: [String]) async -> String?
}

// MARK: - SceneCaptionService (Apple Intelligence via FoundationModels, text-only)

/// Generates short, evocative captions for photos using the on-device
/// FoundationModels framework (macOS 26). The current FoundationModels SDK
/// surface exposes text-only prompts — image content blocks are not available
/// on `Prompt`/`PromptRepresentable`, so we feed the Vision scene labels into
/// the text prompt and ask the model to turn them into one sentence.
///
/// Returns `nil` when the model is unavailable, the request errors out, or
/// when no scene labels are supplied (there would be nothing to caption).
final class SceneCaptionService: SceneCaptionServiceProtocol {

    static let shared = SceneCaptionService()
    private init() {}

    private static let timeoutSeconds: TimeInterval = 8

    private static let instructions: String = """
    You write short, evocative captions for photos used in a music-video montage. \
    One sentence, 8 to 15 words, present tense, no preamble. Describe what's happening \
    or the feeling. Do not wrap the sentence in quotes. Do not use emoji or special characters.
    """

    func caption(for cgImage: CGImage, sceneLabels: [String]) async -> String? {
        // Nothing to caption without at least one label — the text-only pipeline
        // would produce a generic, useless sentence. Callers should display the
        // (empty) labels themselves.
        let cleanLabels = sceneLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanLabels.isEmpty else {
            logger.info("skip caption — no scene labels supplied")
            return nil
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await captionViaFoundationModels(labels: cleanLabels)
        } else {
            logger.warning("FoundationModels requires macOS 26 — returning nil")
            return nil
        }
        #else
        logger.warning("FoundationModels not available in this build — returning nil")
        return nil
        #endif
    }

    // MARK: - FoundationModels path

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func captionViaFoundationModels(labels: [String]) async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            logger.warning("Apple Intelligence unavailable: \(String(describing: reason), privacy: .public)")
            return nil
        }

        let joined = labels.joined(separator: ", ")
        let promptText = "Write a caption for a photo showing: \(joined). One sentence."

        // Race the model against a wall-clock timeout. If the model stalls,
        // return `nil` so the pipeline never blocks on a slow caption.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(to: promptText)
                    let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Model sometimes wraps the sentence in quotes even when
                    // told not to — strip them.
                    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if trimmed.isEmpty {
                        logger.warning("empty caption from FoundationModels")
                        return nil
                    }
                    logger.info("caption ok (\(trimmed.count) chars)")
                    return trimmed
                } catch {
                    logger.warning("FoundationModels error: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                return nil
            }
            // First non-nil wins; if the first result is nil (timeout or
            // model failure), accept it and stop waiting on the other task.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    #endif
}
