import Foundation
import NaturalLanguage

// MARK: - SemanticEnrichmentServiceProtocol

protocol SemanticEnrichmentServiceProtocol {
    func enrichAssets(_ assets: [MediaAsset], onProgress: @escaping (Double, String) -> Void) async -> [MediaAsset]
}

// MARK: - SemanticEmbeddingService

/// On-device semantic embeddings for sequencing. Builds a short text
/// description from each asset's metadata and embeds it with Apple's
/// NLEmbedding so every asset lives in the same vector space.
final class SemanticEmbeddingService: SemanticEnrichmentServiceProtocol {

    static let shared = SemanticEmbeddingService()

    func enrichAssets(_ assets: [MediaAsset], onProgress: @escaping (Double, String) -> Void) async -> [MediaAsset] {
        guard !assets.isEmpty else { return assets }

        var enriched = assets
        onProgress(0.35, "Embedding visual semantics...")
        let sentence = NLEmbedding.sentenceEmbedding(for: .english)
        for i in enriched.indices {
            guard !Task.isCancelled else { return enriched }
            enriched[i].semanticEmbedding = localEmbedding(for: semanticInput(for: enriched[i]), using: sentence)
        }

        onProgress(1.0, "Semantic enrichment complete")
        return enriched
    }

    func semanticInput(for asset: MediaAsset) -> String {
        [
            asset.sceneCaption,
            asset.semanticSummary,
            asset.sceneLabels?.joined(separator: ", "),
            asset.shotType.map { "\($0.rawValue) shot" }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
    }

    func localEmbedding(for text: String, using sentence: NLEmbedding?) -> [Float] {
        // Apple's on-device sentence embedding (free, ~512-dim, real semantic
        // geometry). The hash bag-of-words below only covers the edge case
        // where the embedding model asset isn't available on this Mac.
        if let sentence,
           !text.isEmpty,
           let vec = sentence.vector(for: String(text.prefix(300)).lowercased()) {
            return normalized(vec.map(Float.init))
        }
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
}
