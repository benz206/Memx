import Foundation
import Photos
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "motionprompt")

// MARK: - MotionPromptServiceProtocol

protocol MotionPromptServiceProtocol {
    func generatePrompt(
        for asset: MediaAsset,
        songEnergy: Float,
        sectionType: SectionType?
    ) async throws -> String
}

// MARK: - MotionPromptService (Claude API with mock fallback)

final class MotionPromptService: MotionPromptServiceProtocol {

    static let shared = MotionPromptService()
    private init() {}

    private static let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"

    func generatePrompt(
        for asset: MediaAsset,
        songEnergy: Float,
        sectionType: SectionType?
    ) async throws -> String {
        guard let key = apiKey else {
            logger.debug("No API key — using mock prompt for \(asset.filename ?? asset.id)")
            try await Task.sleep(for: .milliseconds(Int.random(in: 150...300)))
            return mockPrompt(energy: songEnergy, section: sectionType, asset: asset)
        }

        do {
            let result = try await callAPI(asset: asset, energy: songEnergy, section: sectionType, key: key)
            logger.debug("Claude prompt OK for \(asset.filename ?? asset.id): \(result.prefix(60))...")
            return result
        } catch {
            logger.warning("Claude API failed for \(asset.filename ?? asset.id): \(error.localizedDescription) — falling back to mock")
            return mockPrompt(energy: songEnergy, section: sectionType, asset: asset)
        }
    }

    // MARK: - API Key

    private var apiKey: String? {
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty { return envKey }
        if let stored = KeychainHelper.anthropicAPIKey(), !stored.isEmpty { return stored }
        return nil
    }

    // MARK: - Claude API Call

    private func callAPI(asset: MediaAsset, energy: Float, section: SectionType?, key: String) async throws -> String {
        guard PrivacyPreferences.allowAnthropicUploads else {
            throw MotionPromptError.networkUploadsDisabled
        }

        let imageData = await fetchThumbnailData(for: asset.id)

        let energyLabel = energy > 0.8 ? "very high energy" : energy > 0.55 ? "moderate energy" : "low energy"
        let sectionLabel = section?.rawValue ?? "verse"
        let promptText = """
        Generate a single cinematic camera motion direction (1–2 sentences) for this photo in a music video montage. \
        The song is at \(energyLabel) in the \(sectionLabel) section. \
        Describe specific motion: zoom direction, pan, tilt, Ken Burns drift, or parallax. \
        Be precise and evocative. Reply with only the motion direction, no preamble.
        """

        var content: [[String: Any]] = []
        if let imgData = imageData {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": imgData.base64EncodedString()
                ] as [String: Any]
            ])
        }
        content.append(["type": "text", "text": promptText])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 120,
            "messages": [["role": "user", "content": content]]
        ]

        var request = URLRequest(url: Self.apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        return try await performRequestWithRetry(request)
    }

    // MARK: - Retry / Exponential Backoff

    private func performRequestWithRetry(_ request: URLRequest) async throws -> String {
        let maxRetries = 4
        var delay: Double = 1.0

        for attempt in 0...maxRetries {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let status = httpResponse.statusCode

                if status == 200 {
                    return try parseResponse(data)
                }

                let isRetryable = status == 429 || (status >= 500 && status < 600)
                if isRetryable && attempt < maxRetries {
                    var waitSeconds = delay
                    if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let retrySeconds = Double(retryAfter) {
                        waitSeconds = retrySeconds
                    }
                    logger.warning("Claude API HTTP \(status), retry \(attempt + 1)/\(maxRetries) after \(waitSeconds, format: .fixed(precision: 1))s")
                    try await Task.sleep(for: .seconds(waitSeconds))
                    delay = min(delay * 2, 30.0)
                    continue
                }
            }

            throw MotionPromptError.apiError
        }

        throw MotionPromptError.apiError
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArray = json["content"] as? [[String: Any]],
            let firstBlock = contentArray.first,
            let text = firstBlock["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MotionPromptError.parseError
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Image Fetching (512px thumbnail → JPEG)

    private func fetchThumbnailData(for assetID: String) async -> Data? {
        guard let phAsset = await PHAssetCache.shared.phAsset(for: assetID),
              phAsset.mediaType == .image else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = true

        let targetSize = CGSize(width: 512, height: 512)
        let nsImage: NSImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }

        guard let nsImage else { return nil }

        let resized = resizeTo512(nsImage) ?? nsImage
        guard let cgImage = resized.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func resizeTo512(_ image: NSImage) -> NSImage? {
        let origSize = image.size
        let maxDim: CGFloat = 512
        guard origSize.width > maxDim || origSize.height > maxDim else { return image }
        let scale = maxDim / max(origSize.width, origSize.height)
        let newSize = CGSize(width: origSize.width * scale, height: origSize.height * scale)
        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }

    // MARK: - Mock Generator (used when no API key or on API failure)

    private func mockPrompt(energy: Float, section: SectionType?, asset: MediaAsset) -> String {
        if energy > 0.8 || section == .drop {
            return [
                "Fast zoom-in on the center of the frame. Motion blur trails at the edges.",
                "Hard push-in with a slight shake on impact. Cut on peak.",
                "Rapid parallax shift — foreground snaps left, background holds.",
            ].randomElement()!
        }
        if section == .buildup || section == .preChorus {
            return "Slow push-in accelerates as the section builds. Bokeh in the background expands."
        }
        if section == .breakdown || section == .bridge {
            return "Slow Ken Burns drift — wide pull-out. Hold for the full section. Subtle light flicker in the highlights."
        }
        if section == .intro {
            return "Fade in from black. Slow upward tilt as the frame reveals itself."
        }
        if section == .outro {
            return "Slow pull-out with a gentle fade to black. The scene lingers."
        }
        if asset.aspectRatio < 1.0 {
            return "Subtle parallax drift left-to-right. Slight background separation. Bokeh shimmers."
        }
        return [
            "Slow push-in toward the horizon. Morning mist drifts left across the water.",
            "Gentle upward tilt. Clouds drift slowly. Warm light rakes across the surface.",
            "Ken Burns zoom-out, starting tight on the faces. Background falls into soft focus.",
            "Parallax depth: near branches drift left as sky holds steady behind.",
            "Slow push-in with subtle light flicker. Candlelight dances in the corner of the frame.",
            "Tilt up from foreground detail to open sky.",
        ].randomElement()!
    }
}

// MARK: - MotionPromptError

enum MotionPromptError: LocalizedError {
    case apiError
    case parseError
    case networkUploadsDisabled

    var errorDescription: String? {
        switch self {
        case .apiError:               return "Claude API request failed."
        case .parseError:             return "Could not parse Claude API response."
        case .networkUploadsDisabled: return "Network uploads are disabled in Privacy settings."
        }
    }
}
