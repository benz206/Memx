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
        logger.info("caption requested: \(cleanLabels.count) labels")
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
        logger.info("FoundationModels invoke: \(labels.count) labels")
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            logger.warning("Apple Intelligence unavailable: \(String(describing: reason), privacy: .public)")
            return nil
        }

        logger.debug("FoundationModels available — building prompt")
        let joined = labels.joined(separator: ", ")
        let promptText = "Write a caption for a photo showing: \(joined). One sentence."
        logger.debug("FoundationModels prompt (\(promptText.count) chars): \(promptText, privacy: .public)")

        // Race the model against a wall-clock timeout. If the model stalls,
        // return `nil` so the pipeline never blocks on a slow caption.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let start = Date()
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(to: promptText)
                    let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let elapsed = Date().timeIntervalSince(start)
                    logger.info("FoundationModels response in \(elapsed, format: .fixed(precision: 2))s — \(raw.count) chars raw")
                    // Model sometimes wraps the sentence in quotes even when
                    // told not to — strip them.
                    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if trimmed.isEmpty {
                        logger.warning("FoundationModels returned empty content after \(elapsed, format: .fixed(precision: 2))s")
                        return nil
                    }
                    logger.info("FoundationModels caption ok in \(elapsed, format: .fixed(precision: 2))s (\(trimmed.count) chars): \(trimmed, privacy: .public)")
                    return trimmed
                } catch {
                    let elapsed = Date().timeIntervalSince(start)
                    logger.warning("FoundationModels error after \(elapsed, format: .fixed(precision: 2))s: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(Self.timeoutSeconds))
                    logger.warning("FoundationModels timeout after \(Self.timeoutSeconds, format: .fixed(precision: 1))s — using nil caption")
                    return nil
                } catch {
                    return nil
                }
            }
            // First non-nil wins; if the first result is nil (timeout or
            // model failure), accept it and stop waiting on the other task.
            let first = await group.next() ?? nil
            group.cancelAll()
            logger.debug("FoundationModels group resolved (returning \(first == nil ? "nil" : "caption"))")
            return first
        }
    }
    #endif
}
