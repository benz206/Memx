import Foundation

// MARK: - MotionPromptServiceProtocol

protocol MotionPromptServiceProtocol {
    func generatePrompt(
        for asset: MediaAsset,
        songEnergy: Float,
        sectionType: SectionType?
    ) async throws -> String
}

// MARK: - MotionPromptService (mocked — ready for Claude API / local LLM)

final class MotionPromptService: MotionPromptServiceProtocol {

    static let shared = MotionPromptService()
    private init() {}

    func generatePrompt(
        for asset: MediaAsset,
        songEnergy: Float,
        sectionType: SectionType?
    ) async throws -> String {
        // TODO: Replace with Claude API call using the system prompt from spec:
        //   - Send photo as base64 image
        //   - Include sectionType and energy as context
        //   - Parse 1–3 sentence motion direction from response

        try await Task.sleep(for: .milliseconds(Int.random(in: 250...450)))
        return mockPrompt(energy: songEnergy, section: sectionType, asset: asset)
    }

    // MARK: - Mock Generators

    private func mockPrompt(energy: Float, section: SectionType?, asset: MediaAsset) -> String {
        // High energy: dynamic motion
        if energy > 0.8 || section == .drop {
            let opts = [
                "Fast zoom-in on the center of the frame. Motion blur trails at the edges.",
                "Hard push-in with a slight shake on impact. Cut on peak.",
                "Rapid parallax shift — foreground snaps left, background holds.",
            ]
            return opts.randomElement()!
        }

        // Buildup: accelerating motion
        if section == .buildup || section == .preChorus {
            return "Slow push-in accelerates as the section builds. Bokeh in the background expands."
        }

        // Breakdown / Bridge: long hold
        if section == .breakdown || section == .bridge {
            return "Slow Ken Burns drift — wide pull-out. Hold for the full section. Subtle light flicker in the highlights."
        }

        // Intro / Outro
        if section == .intro {
            return "Fade in from black. Slow upward tilt as the frame reveals itself."
        }
        if section == .outro {
            return "Slow pull-out with a gentle fade to black. The scene lingers."
        }

        // Verse / Chorus / default: natural motion
        let isPortrait = asset.aspectRatio < 1.0
        if isPortrait {
            return "Subtle parallax drift left-to-right. Slight background separation. Bokeh shimmers."
        }

        let opts = [
            "Slow push-in toward the horizon. Morning mist drifts left across the water.",
            "Gentle upward tilt. Clouds drift slowly. Warm light rakes across the surface.",
            "Ken Burns zoom-out, starting tight on the faces. Background falls into soft focus.",
            "Parallax depth: near branches drift left as sky holds steady behind.",
            "Slow push-in with subtle light flicker. Candlelight dances in the corner of the frame.",
            "Tilt up from foreground detail to open sky.",
        ]
        return opts.randomElement()!
    }
}
