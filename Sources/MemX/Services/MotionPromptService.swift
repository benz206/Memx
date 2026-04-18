import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.memx.app", category: "motionprompt")

// MARK: - MotionPromptServiceProtocol

protocol MotionPromptServiceProtocol {
    func generatePrompt(
        for asset: MediaAsset,
        songEnergy: Float,
        sectionType: SectionType?
    ) async throws -> String
}

// MARK: - MotionPromptService (on-device Apple Foundation Models with mock fallback)

final class MotionPromptService: MotionPromptServiceProtocol {

    static let shared = MotionPromptService()
    private init() {}

    internal static var _testForceMock = false

    private static let timeoutSeconds: TimeInterval = 6

    private static let instructions: String =
        "You direct cinematic camera motion for a music-video montage. Each response is a single " +
        "1–2 sentence direction describing zoom, pan, tilt, Ken Burns drift, or parallax. " +
        "Be precise and evocative. No preamble, no quotes, no emoji."

    func generatePrompt(
        for asset: MediaAsset,
        songEnergy: Float,
        sectionType: SectionType?
    ) async throws -> String {
        guard !Self._testForceMock else {
            try await Task.sleep(for: .milliseconds(Int.random(in: 150...300)))
            return mockPrompt(energy: songEnergy, section: sectionType, asset: asset)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await generateViaFoundationModels(asset: asset, energy: songEnergy, section: sectionType)
        }
        #endif
        logger.debug("FoundationModels unavailable — using mock for \(asset.filename ?? asset.id)")
        try await Task.sleep(for: .milliseconds(Int.random(in: 150...300)))
        return mockPrompt(energy: songEnergy, section: sectionType, asset: asset)
    }

    // MARK: - FoundationModels path

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateViaFoundationModels(asset: MediaAsset, energy: Float, section: SectionType?) async -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            logger.warning("Apple Intelligence unavailable: \(String(describing: reason), privacy: .public) — using mock")
            return mockPrompt(energy: energy, section: section, asset: asset)
        }

        let prompt = buildPrompt(asset: asset, energy: energy, section: section)
        logger.debug("FoundationModels motion prompt (\(prompt.count) chars)")

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let start = Date()
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(to: prompt)
                    let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let elapsed = Date().timeIntervalSince(start)
                    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if trimmed.isEmpty {
                        logger.warning("FoundationModels empty motion prompt after \(elapsed, format: .fixed(precision: 2))s")
                        return nil
                    }
                    logger.info("FoundationModels motion prompt ok in \(elapsed, format: .fixed(precision: 2))s")
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
                    logger.warning("FoundationModels motion prompt timeout after \(Self.timeoutSeconds, format: .fixed(precision: 1))s")
                    return nil
                } catch {
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let result = first {
                return result
            }
            logger.debug("FoundationModels returned nil — falling back to mock")
            return self.mockPrompt(energy: energy, section: section, asset: asset)
        }
    }

    @available(macOS 26.0, *)
    private func buildPrompt(asset: MediaAsset, energy: Float, section: SectionType?) -> String {
        let energyLabel = energy > 0.8 ? "very high energy" : energy > 0.55 ? "moderate energy" : "low energy"
        let sectionLabel = section?.rawValue ?? "verse"
        let caption = asset.sceneCaption.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        let tags = asset.sceneLabels.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "none"
        return """
        Photo description: \(caption).
        Tags: \(tags).
        Song: \(energyLabel) in the \(sectionLabel) section.
        Write the camera motion direction.
        """
    }
    #endif

    // MARK: - Mock Generator (used when FM is unavailable or times out)

    private func mockPrompt(energy: Float, section: SectionType?, asset: MediaAsset) -> String {
        let base: String
        if energy > 0.8 || section == .drop {
            base = [
                "Fast zoom-in on the center of the frame. Motion blur trails at the edges.",
                "Hard push-in with a slight shake on impact. Cut on peak.",
                "Rapid parallax shift — foreground snaps left, background holds.",
            ].randomElement()!
        } else if section == .buildup || section == .preChorus {
            base = "Slow push-in accelerates as the section builds. Bokeh in the background expands."
        } else if section == .breakdown || section == .bridge {
            base = "Slow Ken Burns drift — wide pull-out. Hold for the full section. Subtle light flicker in the highlights."
        } else if section == .intro {
            base = "Fade in from black. Slow upward tilt as the frame reveals itself."
        } else if section == .outro {
            base = "Slow pull-out with a gentle fade to black. The scene lingers."
        } else if asset.aspectRatio < 1.0 {
            base = "Subtle parallax drift left-to-right. Slight background separation. Bokeh shimmers."
        } else {
            base = [
                "Slow push-in toward the horizon. Morning mist drifts left across the water.",
                "Gentle upward tilt. Clouds drift slowly. Warm light rakes across the surface.",
                "Ken Burns zoom-out, starting tight on the faces. Background falls into soft focus.",
                "Parallax depth: near branches drift left as sky holds steady behind.",
                "Slow push-in with subtle light flicker. Candlelight dances in the corner of the frame.",
                "Tilt up from foreground detail to open sky.",
                "Tilt up from foreground detail to open sky.",
            ].randomElement()!
        }

        if let caption = asset.sceneCaption, !caption.isEmpty {
            return "\(base) Scene: \(caption)"
        }
        return base
    }
}
