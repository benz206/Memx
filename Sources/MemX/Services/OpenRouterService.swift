import Foundation
import OSLog

private let openRouterLogger = Logger(subsystem: "com.memx.app", category: "openrouter")

// MARK: - OpenRouterServiceProtocol

protocol OpenRouterServiceProtocol {
    func enrichAssets(_ assets: [MediaAsset], onProgress: @escaping (Double, String) -> Void) async -> [MediaAsset]
    func generateEditDirection(for asset: MediaAsset, songEnergy: Float, sectionType: SectionType?) async -> String?
}

// MARK: - OpenRouterService

final class OpenRouterService: OpenRouterServiceProtocol {
    static let shared = OpenRouterService()

    private let session: URLSession
    private let apiKeyProvider: () -> String?

    static let embeddingModel = "nvidia/llama-nemotron-embed-vl-1b-v2:free"
    static let textModel = "openrouter/free"

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping () -> String? = {
            ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
                ?? UserDefaults.standard.string(forKey: "OPENROUTER_API_KEY")
                ?? UserDefaults.standard.string(forKey: "openrouter_api_key")
        }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
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
            for i in enriched.indices {
                enriched[i].semanticSummary = localSummary(for: enriched[i])
            }
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

    func generateEditDirection(for asset: MediaAsset, songEnergy: Float, sectionType: SectionType?) async -> String? {
        guard apiKeyProvider()?.isEmpty == false else { return nil }

        let energy = songEnergy > 0.8 ? "very high" : songEnergy > 0.55 ? "medium" : "low"
        let prompt = """
        Write one concise cinematic motion direction for this clip in a beat-synced music video.
        Prioritize matching the visible content, mood, and natural motion. Do not discuss transitions.

        Clip: \(asset.semanticSummary ?? localSummary(for: asset))
        Scene labels: \(asset.sceneLabels?.joined(separator: ", ") ?? "none")
        Section: \(sectionType?.rawValue ?? "unknown")
        Song energy: \(energy)
        Existing motion vector: \(motionDescription(asset.motionVector))
        """
        return await chat(prompt: prompt, temperature: 0.45, maxTokens: 90)
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
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                openRouterLogger.warning("Embedding request failed")
                return nil
            }
            let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
            return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
        } catch {
            openRouterLogger.warning("Embedding request error: \(error.localizedDescription, privacy: .public)")
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
        Each line must be: number. mood | subject | motion-fit | best music-video use
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
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                openRouterLogger.warning("Chat request failed")
                return nil
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            openRouterLogger.warning("Chat request error: \(error.localizedDescription, privacy: .public)")
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
            asset.isVideo ? "video" : "photo",
            motionDescription(asset.motionVector)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
    }

    private func localSummary(for asset: MediaAsset) -> String {
        let subject = asset.sceneCaption ?? asset.sceneLabels?.prefix(3).joined(separator: ", ") ?? asset.filename ?? "visual moment"
        let mood = moodWords(for: asset).joined(separator: " ")
        let motion = motionDescription(asset.motionVector)
        return "\(mood) | \(subject) | \(motion)"
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

        for mood in ["calm", "joy", "warm", "dramatic", "motion", "travel", "family", "detail", "wide", "night"] {
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
        if asset.isVideo || (asset.motionVector?.magnitude ?? 0) > 0.35 { words.append("moving") }
        return words.isEmpty ? ["balanced"] : words
    }

    private func motionDescription(_ vector: MotionVector?) -> String {
        guard let vector else { return "low native motion" }
        let direction: String
        if abs(vector.dx) > abs(vector.dy) {
            direction = vector.dx >= 0 ? "rightward" : "leftward"
        } else {
            direction = vector.dy >= 0 ? "upward" : "downward"
        }
        if vector.magnitude > 0.65 { return "strong \(direction) motion" }
        if vector.magnitude > 0.25 { return "gentle \(direction) motion" }
        return "low native motion"
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
