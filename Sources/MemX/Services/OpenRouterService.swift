import AppKit
import CoreGraphics
import Foundation
import OSLog

private let openRouterLogger = Logger(subsystem: "com.memx.app", category: "openrouter")

// MARK: - OpenRouterServiceProtocol

protocol OpenRouterServiceProtocol {
    var hasAPIKey: Bool { get }
    func analyzeVisualAsset(_ request: OpenRouterVisualAnalysisRequest) async -> OpenRouterVisualAnalysis?
    func enrichAssets(_ assets: [MediaAsset], onProgress: @escaping (Double, String) -> Void) async -> [MediaAsset]
}

struct OpenRouterVisualAnalysisRequest {
    var assetID: String
    var filename: String?
    var isVideo: Bool
    var duration: TimeInterval
    var aspectRatio: Double
    var creationDate: Date?
    var imageJPEGData: Data?
}

struct OpenRouterVisualAnalysis {
    var qualityScore: Float
    var emotionScore: Float
    var noveltyScore: Float
    var eventLabel: String?
    var sceneLabels: [String]
    var sceneCaption: String
    var semanticSummary: String
    var shotType: ShotType
    var colorTemperature: Double
    var faceAreaFraction: Double?
    var clipStartTime: TimeInterval?
    var faces: Int
}

// MARK: - OpenRouterService

final class OpenRouterService: OpenRouterServiceProtocol {
    static let shared = OpenRouterService()

    private let session: URLSession
    private let apiKeyProvider: () -> String?

    static let embeddingModel = "nvidia/llama-nemotron-embed-vl-1b-v2:free"

    /// Default to a free vision-language model so the pipeline works without
    /// burning paid credits. The same NVIDIA VL model handles text-only
    /// summaries and image-grounded analysis. Override either in .env if a
    /// model gets retired (you'll see the 404 in the Analysis tab banner).
    private static let defaultFreeModel = "nvidia/nemotron-nano-12b-v2-vl:free"

    static let textModel: String = {
        ProcessInfo.processInfo.environment["OPENROUTER_TEXT_MODEL"]
            ?? DotEnv.value(forKey: "OPENROUTER_TEXT_MODEL")
            ?? defaultFreeModel
    }()
    static let visionModel: String = {
        ProcessInfo.processInfo.environment["OPENROUTER_VISION_MODEL"]
            ?? DotEnv.value(forKey: "OPENROUTER_VISION_MODEL")
            ?? defaultFreeModel
    }()

    // Per-process counters — surfaced in the Analysis tab so failures don't
    // hide behind a "complete" progress bar.
    private static let countersQueue = DispatchQueue(label: "com.memx.openrouter.counters")
    nonisolated(unsafe) private static var successCount: Int = 0
    nonisolated(unsafe) private static var failureCount: Int = 0
    nonisolated(unsafe) private static var lastFailureSummary: String? = nil
    nonisolated(unsafe) private static var loggedFailures: Int = 0

    static func bumpSuccess() {
        countersQueue.sync { successCount += 1 }
    }
    static func bumpFailure() {
        countersQueue.sync { failureCount += 1 }
    }
    static func resetCounters() {
        countersQueue.sync {
            successCount = 0
            failureCount = 0
            lastFailureSummary = nil
            loggedFailures = 0
        }
    }
    static var stats: (success: Int, failure: Int, lastFailure: String?) {
        countersQueue.sync { (successCount, failureCount, lastFailureSummary) }
    }

    /// Logs the first few HTTP failures with status + body so the user can
    /// see exactly what OpenRouter is rejecting. Caps log volume.
    static func logHTTPFailure(label: String, status: Int, model: String, data: Data) {
        bumpFailure()
        let bodyPreview: String = {
            guard !data.isEmpty,
                  let s = String(data: data.prefix(400), encoding: .utf8) else { return "<no body>" }
            return s.replacingOccurrences(of: "\n", with: " ")
        }()
        let summary = "OpenRouter \(label) HTTP \(status) model=\(model) body=\(bodyPreview)"
        countersQueue.sync {
            lastFailureSummary = summary
            if loggedFailures < 5 {
                loggedFailures += 1
                openRouterLogger.error("\(summary, privacy: .public)")
            }
        }
    }

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping () -> String? = {
            ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
                ?? DotEnv.value(forKey: "OPENROUTER_API_KEY")
                ?? UserDefaults.standard.string(forKey: "OPENROUTER_API_KEY")
                ?? UserDefaults.standard.string(forKey: "openrouter_api_key")
        }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    var hasAPIKey: Bool {
        if let key = apiKeyProvider(), !key.isEmpty { return true }
        return false
    }

    func enrichAssets(_ assets: [MediaAsset], onProgress: @escaping (Double, String) -> Void) async -> [MediaAsset] {
        guard !assets.isEmpty else { return assets }

        var enriched = assets
        let inputs = enriched.map { semanticInput(for: $0) }

        if let summaries = await generateBatchSummaries(for: enriched) {
            for i in enriched.indices {
                enriched[i].semanticSummary = summaries[i]
            }
        } else {
            // OpenRouter unavailable — leave semanticSummary alone (likely
            // empty if visual analysis also fell back). Writing the local
            // boilerplate here would just paint every clip with the same
            // string in the UI.
            openRouterLogger.info("OpenRouter batch summaries unavailable; semanticSummary left empty for fallback assets")
        }

        onProgress(0.35, "Embedding visual semantics...")
        if let remote = await embed(inputs) {
            for i in enriched.indices where i < remote.count {
                enriched[i].semanticEmbedding = normalized(remote[i])
            }
        } else {
            openRouterLogger.info("OpenRouter embeddings unavailable; using local semantic fallback")
            for i in enriched.indices {
                enriched[i].semanticEmbedding = localEmbedding(for: inputs[i])
            }
        }

        onProgress(1.0, "Semantic enrichment complete")
        return enriched
    }

    func analyzeVisualAsset(_ request: OpenRouterVisualAnalysisRequest) async -> OpenRouterVisualAnalysis? {
        guard apiKeyProvider()?.isEmpty == false else { return nil }

        let mediaKind = request.isVideo ? "video representative frame" : "photo"
        let prompt = """
        Analyze this \(mediaKind) for a beat-synced pop music video storyboard.
        Return strict JSON only with these keys:
        qualityScore, emotionScore, noveltyScore: numbers 0...1.
        eventLabel: 2-5 word memory/event cluster.
        sceneLabels: 3-7 short visual tags.
        sceneCaption: one vivid sentence under 16 words.
        semanticSummary: under 22 words: mood | subject | best music-video use.
        shotType: one of wide, medium, closeUp, group, detail.
        colorTemperature: 0 cool/night, 0.5 neutral, 1 warm/golden.
        faceAreaFraction: null or 0...1.
        faces: integer visible faces.
        clipStartTime: best source start time in seconds for a \(Int(max(1, min(6, request.duration)))) second clip; use 0 for photos.

        Filename: \(request.filename ?? "unknown")
        Aspect ratio: \(String(format: "%.2f", request.aspectRatio))
        Duration seconds: \(String(format: "%.1f", request.duration))
        Created: \(request.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "unknown")
        """

        guard let raw = await multimodalChat(
            prompt: prompt,
            imageJPEGData: request.imageJPEGData,
            temperature: 0.18,
            maxTokens: 420
        ), let json = extractJSONObject(from: raw) else {
            return nil
        }

        return OpenRouterVisualAnalysis(
            qualityScore: clampedFloat(json["qualityScore"], fallback: 0.68),
            emotionScore: clampedFloat(json["emotionScore"], fallback: 0.55),
            noveltyScore: clampedFloat(json["noveltyScore"], fallback: 0.50),
            eventLabel: json["eventLabel"] as? String,
            sceneLabels: (json["sceneLabels"] as? [String])?.filter { !$0.isEmpty } ?? [],
            sceneCaption: (json["sceneCaption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            semanticSummary: (json["semanticSummary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            shotType: ShotType(rawValue: json["shotType"] as? String ?? "") ?? .medium,
            colorTemperature: clampedDouble(json["colorTemperature"], min: 0, max: 1, fallback: 0.5),
            faceAreaFraction: optionalClampedDouble(json["faceAreaFraction"], min: 0, max: 1),
            clipStartTime: request.isVideo ? clampedDouble(json["clipStartTime"], min: 0, max: max(0, request.duration), fallback: 0) : nil,
            faces: max(0, Int(clampedDouble(json["faces"], min: 0, max: 100, fallback: 0)))
        )
    }

    func caption(image: CGImage, labels: [String], prompt: String, maxTokens: Int) async -> String? {
        guard let data = Self.jpegData(from: image, maxDimension: 768) else { return nil }
        let labelText = labels.isEmpty ? "none" : labels.joined(separator: ", ")
        let prompt = """
        \(prompt)
        Hint tags: \(labelText)
        Return one present-tense caption, 8 to 15 words, no quotes.
        """
        return await multimodalChat(prompt: prompt, imageJPEGData: data, temperature: 0.25, maxTokens: maxTokens)
    }

    // MARK: - Remote Calls

    private func embed(_ inputs: [String]) async -> [[Float]]? {
        guard let key = apiKeyProvider(), !key.isEmpty else { return nil }
        guard let url = URL(string: "https://openrouter.ai/api/v1/embeddings") else { return nil }

        let body = EmbeddingRequest(input: inputs, model: Self.embeddingModel, encodingFormat: "float")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MemX", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                Self.logHTTPFailure(label: "embed", status: status, model: Self.embeddingModel, data: data)
                return nil
            }
            let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
            Self.bumpSuccess()
            return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
        } catch {
            openRouterLogger.warning("Embedding request error: \(error.localizedDescription, privacy: .public)")
            Self.bumpFailure()
            return nil
        }
    }

    private func generateBatchSummaries(for assets: [MediaAsset]) async -> [String]? {
        guard apiKeyProvider()?.isEmpty == false else { return nil }
        let compact = assets.enumerated().map { idx, asset in
            "\(idx + 1). \(semanticInput(for: asset))"
        }.joined(separator: "\n")
        let prompt = """
        For each numbered photo/video, return a compact edit summary in the same order.
        Each line must be: number. mood | subject | best music-video use
        Keep each line under 18 words.

        \(compact)
        """
        guard let raw = await chat(prompt: prompt, temperature: 0.25, maxTokens: min(1200, max(160, assets.count * 28))) else {
            return nil
        }
        let parsed = raw
            .split(separator: "\n")
            .map { line in
                line.replacingOccurrences(of: #"^\s*\d+[\).\s-]*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        guard parsed.count == assets.count else { return nil }
        return parsed
    }

    private func chat(prompt: String, temperature: Double, maxTokens: Int) async -> String? {
        guard let key = apiKeyProvider(), !key.isEmpty else { return nil }
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return nil }

        let body = ChatRequest(
            model: Self.textModel,
            messages: [
                ChatMessage(role: "system", content: "You are an expert music-video editor. Be concrete, visual, and concise."),
                ChatMessage(role: "user", content: prompt)
            ],
            temperature: temperature,
            maxTokens: maxTokens
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MemX", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                Self.logHTTPFailure(label: "chat", status: status, model: Self.textModel, data: data)
                return nil
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            Self.bumpSuccess()
            return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            openRouterLogger.warning("Chat request error: \(error.localizedDescription, privacy: .public)")
            Self.bumpFailure()
            return nil
        }
    }

    private func multimodalChat(prompt: String, imageJPEGData: Data?, temperature: Double, maxTokens: Int) async -> String? {
        guard let key = apiKeyProvider(), !key.isEmpty else { return nil }
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return nil }

        var content: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        if let imageJPEGData {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(imageJPEGData.base64EncodedString())"]
            ])
        }

        let payload: [String: Any] = [
            "model": Self.visionModel,
            "messages": [
                ["role": "system", "content": "You are a precise visual story editor for music videos. Follow output schemas exactly."],
                ["role": "user", "content": content]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MemX", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                Self.logHTTPFailure(label: "multimodal", status: status, model: Self.visionModel, data: data)
                return nil
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            Self.bumpSuccess()
            return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            openRouterLogger.warning("Multimodal chat error: \(error.localizedDescription, privacy: .public)")
            Self.bumpFailure()
            return nil
        }
    }

    // MARK: - Local Semantic Fallback

    private func semanticInput(for asset: MediaAsset) -> String {
        [
            asset.sceneCaption,
            asset.sceneLabels?.joined(separator: ", "),
            asset.eventLabel,
            asset.shotType?.rawValue,
            asset.isVideo ? "video" : "photo"
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
    }

    private func localSummary(for asset: MediaAsset) -> String {
        let subject = asset.sceneCaption ?? asset.sceneLabels?.prefix(3).joined(separator: ", ") ?? asset.filename ?? "visual moment"
        let mood = moodWords(for: asset).joined(separator: " ")
        return "\(mood) | \(subject)"
    }

    private func localEmbedding(for text: String) -> [Float] {
        var vector = Array(repeating: Float(0), count: 96)
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for word in words {
            let hash = stableHash(word)
            let index = Int(hash % UInt64(vector.count))
            let sign: Float = ((hash >> 8) & 1) == 0 ? 1 : -1
            vector[index] += sign
        }

        for mood in ["calm", "joy", "warm", "dramatic", "travel", "family", "detail", "wide", "night"] {
            if text.localizedCaseInsensitiveContains(mood) {
                vector[Int(stableHash("mood-\(mood)") % UInt64(vector.count))] += 2
            }
        }
        return normalized(vector)
    }

    private func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private func moodWords(for asset: MediaAsset) -> [String] {
        var words = [String]()
        if (asset.emotionScore ?? 0) > 0.72 { words.append("emotional") }
        if (asset.noveltyScore ?? 0) > 0.70 { words.append("distinct") }
        if (asset.colorTemperature ?? 0.5) > 0.62 { words.append("warm") }
        if (asset.colorTemperature ?? 0.5) < 0.38 { words.append("cool") }
        if asset.isVideo { words.append("video") }
        return words.isEmpty ? ["balanced"] : words
    }

    static func jpegData(from cgImage: CGImage, maxDimension: CGFloat = 768, compressionQuality: CGFloat = 0.72) -> Data? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
        let image = NSImage(cgImage: cgImage, size: size)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    private func extractJSONObject(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else { return nil }
        let jsonText = String(trimmed[start...end])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func clampedFloat(_ value: Any?, fallback: Float) -> Float {
        Float(clampedDouble(value, min: 0, max: 1, fallback: Double(fallback)))
    }

    private func optionalClampedDouble(_ value: Any?, min: Double, max: Double) -> Double? {
        guard !(value is NSNull), value != nil else { return nil }
        return clampedDouble(value, min: min, max: max, fallback: min)
    }

    private func clampedDouble(_ value: Any?, min: Double, max: Double, fallback: Double) -> Double {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let string = value as? String {
            raw = Double(string)
        } else {
            raw = nil
        }
        guard let raw else { return fallback }
        return Swift.min(max, Swift.max(min, raw))
    }
}

// MARK: - DTOs

private struct EmbeddingRequest: Encodable {
    let input: [String]
    let model: String
    let encodingFormat: String

    enum CodingKeys: String, CodingKey {
        case input, model
        case encodingFormat = "encoding_format"
    }
}

private struct EmbeddingResponse: Decodable {
    let data: [EmbeddingData]
}

private struct EmbeddingData: Decodable {
    let embedding: [Float]
    let index: Int
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatMessage
}
