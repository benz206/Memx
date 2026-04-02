import Foundation

// MARK: - AnalysisServiceProtocol

protocol AnalysisServiceProtocol {
    func runAnalysis(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (AnalysisJobStatus) -> Void
    ) async throws -> AnalysisResult
}

// MARK: - AnalysisResult

struct AnalysisResult {
    var scoredAssets: [MediaAsset]
    var events: [MemoryEvent]
    var scenes: [SceneSegment]
    var candidates: [ClipCandidate]
}

// MARK: - AnalysisService (mocked pipeline — ready for on-device ML)

final class AnalysisService: AnalysisServiceProtocol {

    static let shared = AnalysisService()
    private init() {}

    func runAnalysis(
        for project: Project,
        assets: [MediaAsset],
        onProgress: @escaping (AnalysisJobStatus) -> Void
    ) async throws -> AnalysisResult {

        var status = AnalysisJobStatus(projectID: project.id)

        // Phase 1: Load assets
        status.phase = .loadingAssets
        status.progress = 0.05
        status.message = "Loading \(assets.count) assets..."
        onProgress(status)
        try await Task.sleep(for: .milliseconds(600))

        // Phase 2: Scene detection
        status.phase = .detectingScenes
        status.progress = 0.2
        status.message = "Detecting scenes in \(assets.count) media files..."
        onProgress(status)
        let scenes = generateMockScenes(for: assets)
        try await Task.sleep(for: .milliseconds(900))

        // Phase 3: Embedding extraction
        // TODO: Replace with Core ML Vision embedding model (e.g., CLIP-style VisionTransformer)
        status.phase = .extractingEmb
        status.progress = 0.4
        status.message = "Extracting visual embeddings... (on-device)"
        onProgress(status)
        try await Task.sleep(for: .milliseconds(1200))

        // Phase 4: Event clustering
        // TODO: Replace with DBSCAN/K-Means over real embedding vectors
        status.phase = .clusteringEvents
        status.progress = 0.6
        status.message = "Clustering moments into events..."
        onProgress(status)
        let events = generateMockEvents(for: assets, scenes: scenes)
        try await Task.sleep(for: .milliseconds(700))

        // Phase 5: Moment scoring
        // TODO: Replace with learned ranking model (quality × emotion × novelty)
        status.phase = .scoringMoments
        status.progress = 0.75
        status.message = "Scoring \(assets.count) moments..."
        onProgress(status)
        let scoredAssets = scoreAssets(assets, scenes: scenes, events: events)
        let candidates = buildCandidates(from: scoredAssets, scenes: scenes)
        try await Task.sleep(for: .milliseconds(500))

        // Phase 6: Soundtrack selection
        status.phase = .selectingSong
        status.progress = 0.88
        status.message = "Matching mood profile to soundtrack..."
        onProgress(status)
        try await Task.sleep(for: .milliseconds(400))

        // Phase 7: Storyboard build
        status.phase = .buildingStoryboard
        status.progress = 0.95
        status.message = "Assembling optimal storyboard..."
        onProgress(status)
        try await Task.sleep(for: .milliseconds(500))

        // Done
        status.phase = .complete
        status.progress = 1.0
        status.message = "Analysis complete"
        status.completedAt = Date()
        onProgress(status)

        return AnalysisResult(
            scoredAssets: scoredAssets,
            events: events,
            scenes: scenes,
            candidates: candidates
        )
    }

    // MARK: - Mock Generators

    private func generateMockScenes(for assets: [MediaAsset]) -> [SceneSegment] {
        let labels = [
            "outdoor · golden hour · group",
            "indoor · bright · portrait",
            "landscape · wide shot · scenery",
            "close-up · candid · emotional",
            "action · dynamic motion · group",
            "night · ambient light · intimate",
            "food · table · social",
            "water · blue tones · calm",
            "celebration · confetti · joy"
        ]
        let objects = [
            ["person", "smile", "outdoor"],
            ["food", "table", "indoor"],
            ["mountain", "sky", "landscape"],
            ["water", "reflection", "sunset"],
            ["group", "activity", "motion"]
        ]
        return assets.map { asset in
            SceneSegment(
                assetID: asset.id,
                segmentStart: 0,
                segmentEnd: asset.duration > 0 ? asset.duration : 0,
                sceneLabel: labels.randomElement()!,
                qualityScore: Float.random(in: 0.5...1.0),
                detectedObjects: objects.randomElement()!
            )
        }
    }

    private func generateMockEvents(for assets: [MediaAsset], scenes: [SceneSegment]) -> [MemoryEvent] {
        let eventTemplates: [(String, String, Emotion)] = [
            ("Arrival & First Looks", "The opening moments — fresh, anticipatory, full of energy.", .excitement),
            ("Golden Hour Walk", "Late afternoon light catches everything beautifully.", .awe),
            ("Group Laughs", "Unscripted candid moments between friends.", .humor),
            ("The Quiet In-Between", "Softer, slower beats — a breath in the story.", .calm),
            ("Peak Celebration", "The moment everyone came for. Energy at its highest.", .joy),
            ("Farewell & Reflection", "Winding down — nostalgic and warm.", .nostalgia),
            ("Hidden Gems", "Overlooked moments that deserve the spotlight.", .surprise),
        ]

        let chunkSize = max(1, assets.count / eventTemplates.count)
        var events: [MemoryEvent] = []

        for (i, template) in eventTemplates.prefix(min(eventTemplates.count, (assets.count / chunkSize) + 1)).enumerated() {
            let start = i * chunkSize
            let end = min(start + chunkSize, assets.count)
            guard start < assets.count else { break }
            let chunk = Array(assets[start..<end])
            var event = MemoryEvent(
                label: template.0,
                description: template.1,
                assetIDs: chunk.map(\.id),
                dominantEmotion: template.2,
                importanceScore: Float.random(in: 0.6...1.0)
            )
            event.startDate = chunk.compactMap(\.creationDate).min()
            event.endDate = chunk.compactMap(\.creationDate).max()
            event.representativeAssetID = chunk.max(by: { ($0.analysisScore ?? 0) < ($1.analysisScore ?? 0) })?.id
            events.append(event)
        }
        return events
    }

    private func scoreAssets(_ assets: [MediaAsset], scenes: [SceneSegment], events: [MemoryEvent]) -> [MediaAsset] {
        var scored = assets
        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.assetID, $0) })

        for i in scored.indices {
            let scene = sceneMap[scored[i].id]
            let quality   = scene?.qualityScore ?? Float.random(in: 0.4...1.0)
            let emotion   = Float.random(in: 0.3...1.0)
            let novelty   = Float.random(in: 0.2...1.0)
            // TODO: Replace with dot-product similarity against query embedding
            let overall   = quality * 0.4 + emotion * 0.35 + novelty * 0.25

            scored[i].qualityScore = quality
            scored[i].emotionScore = emotion
            scored[i].noveltyScore = novelty
            scored[i].analysisScore = overall

            // Assign event label
            for event in events where event.assetIDs.contains(scored[i].id) {
                scored[i].eventLabel = event.label
                break
            }
        }
        return scored
    }

    private func buildCandidates(from assets: [MediaAsset], scenes: [SceneSegment]) -> [ClipCandidate] {
        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.assetID, $0) })
        return assets.compactMap { asset in
            guard let score = asset.analysisScore else { return nil }
            let scene = sceneMap[asset.id]
            let duration = asset.isVideo ? min(asset.duration, 5.0) : 0
            return ClipCandidate(
                assetID: asset.id,
                clipStart: 0,
                clipEnd: duration,
                overallScore: score,
                qualityScore: asset.qualityScore ?? 0.7,
                emotionScore: asset.emotionScore ?? 0.6,
                noveltyScore: asset.noveltyScore ?? 0.5,
                motionScore: asset.isVideo ? Float.random(in: 0.4...1.0) : 0,
                faces: Int.random(in: 0...4),
                isIncluded: score > 0.45
            )
        }
    }
}
