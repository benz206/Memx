# MemX — Setup & AI Integration Guide

---

## Part 1 — Project Setup

### Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.2+
- Swift 5.9+

### Build & run

```bash
swift build
swift run MemX
```

Or open `Package.swift` in Xcode (generates `.swiftpm` workspace automatically).

### Entitlements

In Xcode: Target → Signing & Capabilities → add the following:

1. **App Sandbox**
2. **Photos Library** (read-write)
3. File Access → **Downloads Folder** (read-write) — needed for export temp files

Or copy `MemoryStitcher.entitlements` and point Build Settings → Code Signing Entitlements to it.

### Info.plist keys

These are already in `Sources/MemX/Resources/Info.plist`. If you create a fresh Xcode target, add:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>MemX accesses your Photos library to import photos and videos for your montage. All processing happens locally on your device.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>MemX may save rendered montages back to your Photos library.</string>
```

---

## Part 2 — AI Integration

The full pipeline runs today with mock data. Every AI hook has a `// TODO:` comment marking the exact line to replace. This section walks through each one.

### Overview of the pipeline

```
Photos assets
    │
    ▼ exportAssetForProcessing()          PhotosLibraryService.swift
    │  → exports to temp URL (jpg / mov)
    │
    ▼ Phase 2: Scene detection            AnalysisService.swift:generateMockScenes()
    │  → SceneSegment[] with labels,
    │    qualityScore, detectedObjects
    │
    ▼ Phase 3: Embedding extraction       AnalysisService.swift (Phase .extractingEmb)
    │  → SceneSegment.embedding [Float]
    │
    ▼ Phase 4: Event clustering           AnalysisService.swift:generateMockEvents()
    │  → MemoryEvent[] grouped by similarity
    │
    ▼ Phase 5: Moment scoring             AnalysisService.swift:scoreAssets()
    │  → MediaAsset.qualityScore / emotionScore / noveltyScore / analysisScore
    │
    ▼ MontagePlannerService               MontagePlannerService.swift
    │  → MontagePlan with sequence, mood arc
    │
    ▼ MusicSuggestionService              MusicSuggestionService.swift
    │  → SongSuggestion[] matched to mood arc
    │
    ▼ (future) Render pipeline            StoryboardView.swift
       → AVMutableComposition → .mov export
```

---

### Step 1 — Scene detection & quality scoring

**File:** `Sources/MemX/Services/AnalysisService.swift`  
**Method:** `generateMockScenes(for:)` — replace the mock `SceneSegment` generation.

The `SceneSegment` struct carries: `sceneLabel`, `qualityScore`, `blurScore`, `exposureScore`, `compositionScore`, `detectedObjects`.

**Replace with Vision framework requests:**

```swift
import Vision

func detectScenes(for asset: MediaAsset) async throws -> SceneSegment {
    guard let url = try? await PhotosLibraryService.shared.exportAssetForProcessing(asset.id),
          let ciImage = CIImage(contentsOf: url) else {
        return SceneSegment(assetID: asset.id, sceneLabel: "unknown")
    }

    // 1. Aesthetic quality (macOS 14+)
    let aestheticsRequest = VNGenerateImageAestheticsScoresRequest()

    // 2. Object recognition
    let objectRequest = VNRecognizeObjectsRequest()
    objectRequest.revision = VNRecognizeObjectsRequestRevision1

    // 3. Attention saliency (identifies the most visually important region)
    let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
    try handler.perform([aestheticsRequest, objectRequest, saliencyRequest])

    let aestheticsScore = (aestheticsRequest.results?.first as? VNImageAestheticsScoresObservation)
    let quality = Float(aestheticsScore?.overallScore ?? 0.7)

    let objects = (objectRequest.results as? [VNRecognizedObjectObservation])?
        .compactMap { $0.labels.first?.identifier } ?? []

    let sceneLabel = objects.prefix(3).joined(separator: " · ")

    return SceneSegment(
        assetID: asset.id,
        sceneLabel: sceneLabel.isEmpty ? "scene" : sceneLabel,
        qualityScore: quality,
        detectedObjects: objects
    )
}
```

**Face detection** — feed into `ClipCandidate.faces`:

```swift
let faceRequest = VNDetectFaceRectanglesRequest()
try handler.perform([faceRequest])
let faceCount = faceRequest.results?.count ?? 0
```

---

### Step 2 — Visual embeddings

**File:** `Sources/MemX/Services/AnalysisService.swift`  
**Location:** Phase `.extractingEmb` (around line 53) — currently just a `Task.sleep`.

The `SceneSegment` struct already has `embedding: [Float]?` ready to receive the vector.

**Option A — Apple's built-in feature print (simplest, no model download):**

```swift
import Vision

func extractEmbedding(from url: URL) async throws -> [Float] {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(url: url, options: [:])
    try handler.perform([request])

    guard let obs = request.results?.first as? VNFeaturePrintObservation else { return [] }

    // Convert to [Float] for storage in SceneSegment.embedding
    var result = [Float](repeating: 0, count: obs.elementCount)
    // VNFeaturePrintObservation doesn't expose raw floats directly;
    // use computeDistance for comparison instead (see clustering step).
    // To store as [Float], use the data property:
    obs.data.withUnsafeBytes { ptr in
        let floatPtr = ptr.bindMemory(to: Float.self)
        result = Array(floatPtr)
    }
    return result
}
```

**Option B — Core ML CLIP model (better cross-modal similarity):**

1. Download a converted CLIP ViT-B/32 `.mlpackage` (e.g. from Apple's ML Models page or convert via `coremltools`).
2. Add the `.mlpackage` to your Xcode target.
3. Xcode auto-generates a Swift class (e.g. `CLIPImageEncoder`).

```swift
import CoreML
import Vision

func extractCLIPEmbedding(from url: URL) async throws -> [Float] {
    let model = try CLIPImageEncoder(configuration: MLModelConfiguration())
    guard let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

    let input = CLIPImageEncoderInput(imageWith: cgImage)
    let output = try model.prediction(input: input)
    // Shape: [512] for ViT-B/32
    return output.embedding.map { Float(truncating: $0) }
}
```

> Tip: store embeddings in `SceneSegment.embedding` after phase 3 and pass `scenes` into the clustering step.

---

### Step 3 — Event clustering

**File:** `Sources/MemX/Services/AnalysisService.swift`  
**Method:** `generateMockEvents(for:scenes:)` — replace with real clustering over `SceneSegment.embedding`.

**K-Means (simple, fast):**

```swift
func clusterByKMeans(scenes: [SceneSegment], k: Int = 7) -> [MemoryEvent] {
    // 1. Collect embeddings — skip scenes without one
    let vectors = scenes.compactMap { $0.embedding }
    guard vectors.count >= k else { return [] }

    // 2. Random initial centroids
    var centroids = Array(vectors.shuffled().prefix(k))

    for _ in 0..<20 {  // iterate until stable
        // Assign each scene to nearest centroid
        var clusters: [Int: [Int]] = [:]
        for (i, vec) in vectors.enumerated() {
            let nearest = centroids.indices.min(by: {
                cosineDistance(vec, centroids[$0]) < cosineDistance(vec, centroids[$1])
            })!
            clusters[nearest, default: []].append(i)
        }

        // Recompute centroids
        for (clusterID, indices) in clusters {
            let clusterVecs = indices.map { vectors[$0] }
            centroids[clusterID] = meanVector(clusterVecs)
        }
    }

    // 3. Build MemoryEvent per cluster
    // ... map cluster indices back to asset IDs
}

func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    let dot = zip(a, b).map(*).reduce(0, +)
    let magA = sqrt(a.map { $0 * $0 }.reduce(0, +))
    let magB = sqrt(b.map { $0 * $0 }.reduce(0, +))
    return 1.0 - (dot / (magA * magB + 1e-8))
}

func meanVector(_ vecs: [[Float]]) -> [Float] {
    guard let first = vecs.first else { return [] }
    var sum = [Float](repeating: 0, count: first.count)
    for v in vecs { for i in v.indices { sum[i] += v[i] } }
    return sum.map { $0 / Float(vecs.count) }
}
```

**Using `VNFeaturePrintObservation.computeDistance` (Option A embeddings only):**

If you went with `VNFeaturePrintObservation`, keep the observations in memory and use the built-in distance instead of raw vectors:

```swift
try obs1.computeDistance(&distance, to: obs2)
```

---

### Step 4 — Moment scoring

**File:** `Sources/MemX/Services/AnalysisService.swift`  
**Method:** `scoreAssets(_:scenes:events:)` — line `// TODO: Replace with dot-product similarity`.

The current scoring formula (keep this structure):

```
overallScore = quality * 0.4 + emotion * 0.35 + novelty * 0.25
```

Replace the random values with:

- **`qualityScore`** — `VNGenerateImageAestheticsScoresRequest().overallScore` from Step 1.
- **`emotionScore`** — Run `VNDetectFaceLandmarksRequest` and score emotional expressiveness from landmark geometry, or use a Create ML classifier trained on labelled face crops.
- **`noveltyScore`** — Cosine distance from the cluster centroid embedding. Clips far from the centroid are visually distinct within their event (good) but too far is an outlier (bad); normalise into 0–1.

```swift
// In scoreAssets(), replace random values:
let quality   = scene?.qualityScore ?? 0.5
let novelty   = clampedNovelty(embedding: scene?.embedding, centroid: clusterCentroid)
let emotion   = faceEmotionScore(for: asset)  // see Step 4a below
let overall   = quality * 0.4 + emotion * 0.35 + novelty * 0.25

func clampedNovelty(embedding: [Float]?, centroid: [Float]) -> Float {
    guard let e = embedding else { return 0.5 }
    let dist = cosineDistance(e, centroid)
    // dist in [0, 2]; remap to a 0-1 novelty score peaked at moderate distance
    return Float(1.0 - abs(Double(dist) - 0.4) / 0.6)
}
```

**Step 4a — Emotion scoring from faces:**

```swift
import Vision

func faceEmotionScore(for asset: MediaAsset) async -> Float {
    guard let url = try? await PhotosLibraryService.shared.exportAssetForProcessing(asset.id),
          let ciImage = CIImage(contentsOf: url) else { return 0.5 }

    let request = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
    try? handler.perform([request])

    guard let faces = request.results, !faces.isEmpty else { return 0.3 }
    // More faces + higher confidence = higher emotional content
    let avgConf = faces.map { Float($0.confidence) }.reduce(0, +) / Float(faces.count)
    return min(1.0, avgConf * Float(faces.count) * 0.4)
}
```

---

### Step 5 — Music matching with MusicKit

**File:** `Sources/MemX/Services/MusicSuggestionService.swift`  
**Method:** `suggestSongs(for:moodArc:)` — replace the mock catalog search.

**Add MusicKit entitlement:**

Xcode → Target → Signing & Capabilities → `+` → **MusicKit**.

**Request authorization once (call from AppViewModel on launch):**

```swift
import MusicKit

func requestMusicAuthorization() async {
    _ = await MusicAuthorization.request()
}
```

**Replace `suggestSongs` body:**

```swift
import MusicKit

func suggestSongs(for settings: MontageSettings, moodArc: [MoodPoint]) async -> [SongSuggestion] {
    guard await MusicAuthorization.currentStatus == .authorized else { return [] }

    // Map your vibe enum to genre search terms
    let searchTerm: String = switch settings.vibe {
    case .hype:       "energetic upbeat"
    case .nostalgic:  "nostalgic indie acoustic"
    case .cinematic:  "cinematic orchestral"
    case .wholesome:  "wholesome feel good"
    case .funny:      "playful fun"
    case .travel:     "adventure travel"
    }

    var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
    request.limit = 10
    let response = try? await request.response()

    return response?.songs.compactMap { song -> SongSuggestion? in
        guard let duration = song.duration else { return nil }
        return SongSuggestion(
            title: song.title,
            artist: song.artistName,
            genre: settings.musicPreference,
            bpm: 0,                     // MusicKit doesn't expose BPM — use AudioAnalysis if available
            durationSeconds: Int(duration),
            moodTags: [searchTerm],
            vibeMatch: 0.8,
            energyLevel: Float(moodArc.map(\.energy).reduce(0, +) / max(1, Double(moodArc.count)))
        )
    } ?? []
}
```

> MusicKit `AudioAnalysis` (available via `Song.audioAnalysis()`) provides BPM and key when available. Gated behind an additional entitlement request on some accounts.

---

### Step 6 — Export & render pipeline

**File:** `Sources/MemX/Views/Workspace/Storyboard/StoryboardView.swift`  
**Location:** Look for `renderPipelinePlaceholder` — this is where to hook in the render call.

The `MontagePlan.sequence` already has everything needed: `assetID`, `clipStart`, `clipEnd`, `transitionType`, `estimatedFinalStart`.

**Basic render function** (add to `WorkspaceViewModel` or a new `RenderService`):

```swift
import AVFoundation

func renderMontage(plan: MontagePlan) async throws -> URL {
    let composition = AVMutableComposition()
    let videoTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
    )!
    let audioTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
    )!

    var insertTime = CMTime.zero

    for item in plan.sequence {
        guard let phAsset = PhotosLibraryService.shared.fetchAsset(for: item.assetID) else { continue }
        let url = try await PhotosLibraryService.shared.exportAssetForProcessing(item.assetID)
        let asset = AVURLAsset(url: url)

        let clipRange = CMTimeRange(
            start: CMTime(seconds: item.clipStart, preferredTimescale: 600),
            end:   CMTime(seconds: item.clipEnd,   preferredTimescale: 600)
        )

        if let srcVideo = try? await asset.loadTracks(withMediaType: .video).first {
            try videoTrack.insertTimeRange(clipRange, of: srcVideo, at: insertTime)
        }
        if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
            try? audioTrack.insertTimeRange(clipRange, of: srcAudio, at: insertTime)
        }

        insertTime = insertTime + clipRange.duration
    }

    // Transitions via AVVideoComposition (crossDissolve shown)
    let videoComposition = AVMutableVideoComposition(
        propertiesOf: composition
    )
    // For per-clip transitions, set up AVMutableVideoCompositionInstruction manually.

    // Export
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")

    guard let session = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPreset1920x1080
    ) else { throw RenderError.sessionFailed }

    session.outputURL = outputURL
    session.outputFileType = .mov
    session.videoComposition = videoComposition

    await session.export()

    guard session.status == .completed else {
        throw session.error ?? RenderError.exportFailed
    }
    return outputURL
}

enum RenderError: Error {
    case sessionFailed
    case exportFailed
}
```

> For crossDissolve transitions between clips, set up `AVMutableVideoCompositionInstruction` with two `AVMutableVideoCompositionLayerInstruction`s and animate `setOpacityRamp` over the transition window defined by each `MontageSequenceItem.transitionType.defaultDuration`.

---

## Part 3 — Recommended Model Sources

| Component | Source |
|---|---|
| Aesthetic quality | `VNGenerateImageAestheticsScoresRequest` — built into macOS 14, no download |
| Object recognition | `VNRecognizeObjectsRequest` — built-in |
| Feature embeddings | `VNGenerateImageFeaturePrintRequest` — built-in; or download a CLIP `.mlpackage` |
| CLIP model | [Apple ML Models](https://developer.apple.com/machine-learning/models/) or convert with `coremltools` from HuggingFace `openai/clip-vit-base-patch32` |
| Emotion classifier | Train with Create ML on a labelled face expression dataset, or use the Vision face landmarks + geometric heuristics |
| Music | MusicKit (Apple Music subscription required on device) |

---

## Part 4 — Development Tips

**Run without Photos permission** — all services return mock data automatically. `MockDataProvider` seeds projects, assets, events, and songs. No real library access needed during development.

**Swap a single AI step** — each phase in `AnalysisService.runAnalysis` calls an isolated private method. Replace one at a time; the rest keep returning mock values. The pipeline is additive.

**Test embedding distances** — log `cosineDistance(a, b)` for a handful of asset pairs before wiring up clustering. Expect similar-scene assets to score < 0.3 and unrelated ones > 0.7.

**MusicKit sandbox** — MusicKit works in the simulator only if the device/simulator is signed into an Apple ID with an active Apple Music subscription.
