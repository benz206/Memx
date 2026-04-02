# MemX

A macOS 14+ SwiftUI app that turns your Photos library into a cinematic memory montage. All processing runs on-device — no cloud, no subscriptions.

Import photos and videos, let the AI pipeline analyze and cluster them into narrative events, then get a scored storyboard with transitions and a matched soundtrack. The AI layer is fully mocked today and ready to be wired to real on-device models.

---

## Status

| Layer | Status |
|---|---|
| Photos import + album browsing | Working |
| Mock analysis pipeline (8 phases) | Working |
| Storyboard assembly + mood arc | Working |
| Song matching (mock catalog) | Working |
| Core ML scene detection | Not yet — see [AI Setup](#ai-setup) |
| Vision embeddings + clustering | Not yet — see [AI Setup](#ai-setup) |
| MusicKit integration | Not yet — see [AI Setup](#ai-setup) |
| AVFoundation render + export | Not yet — see [AI Setup](#ai-setup) |

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.2 or later
- Swift 5.9+

---

## Build & Run

```bash
git clone <repo>
cd Memx
swift build
swift run MemX
```

Or open `Package.swift` directly in Xcode — it auto-generates the `.swiftpm` workspace. Press `Cmd+R`.

On first launch the app requests Photos access and falls back to mock data if denied, so it works in the simulator or without a real library.

---

## Architecture

```
MemXApp  →  ContentView
              ↓
         AppViewModel          (global nav, project list, persistence)
              ↓
         WorkspaceViewModel    (per-project: assets, analysis, storyboard)
         ImportViewModel       (album picker, PhotosPicker integration)
              ↓
         AnalysisService       ← plug Core ML here
         MontagePlannerService ← storyboard assembly logic
         MusicSuggestionService← plug MusicKit here
         PhotosLibraryService  ← real PhotoKit (exportAssetForProcessing ready)
```

All services are protocol-based. Swap in real implementations without touching view code.

---

## AI Setup

All AI hooks are in place with `// TODO:` comments. The pipeline runs end-to-end with mock data today. Below is how to wire each real model.

See [SETUP.md](SETUP.md) for full step-by-step instructions.

### Pipeline overview

```
Photos assets
    ↓  PhotosLibraryService.exportAssetForProcessing()   → temp file URLs
    ↓  AnalysisService — Phase 2: scene detection        → SceneSegment[]
    ↓  AnalysisService — Phase 3: embeddings             → SceneSegment.embedding [Float]
    ↓  AnalysisService — Phase 4: event clustering       → MemoryEvent[]
    ↓  AnalysisService — Phase 5: moment scoring         → MediaAsset.analysisScore
    ↓  MontagePlannerService                             → MontagePlan
    ↓  MusicSuggestionService                            → SongSuggestion[]
    ↓  (future) AVMutableComposition render              → exported .mov
```

### Quick-reference: what to replace

| File | Method | Replace with |
|---|---|---|
| `AnalysisService.swift` | `generateMockScenes()` | `VNGenerateImageAestheticsScoresRequest` + `VNRecognizeObjectsRequest` |
| `AnalysisService.swift` | Phase `.extractingEmb` | Core ML CLIP model or `VNGenerateImageFeaturePrintRequest` |
| `AnalysisService.swift` | `generateMockEvents()` | K-Means or DBSCAN over `SceneSegment.embedding` vectors |
| `AnalysisService.swift` | `scoreAssets()` | Dot-product similarity against a query embedding |
| `MusicSuggestionService.swift` | `suggestSongs()` | `MusicKit.MusicCatalogSearchRequest` |
| `StoryboardView.swift` | render placeholder | `AVMutableComposition` + `AVAssetExportSession` |

---

## Project Structure

```
Sources/MemX/
├── App/                   MemXApp.swift, ContentView.swift
├── Models/                Project, MediaAsset, MontagePlan, AnalysisModels
├── Services/              PhotosLibraryService, AnalysisService,
│                          MontagePlannerService, MusicSuggestionService
├── ViewModels/            AppViewModel, WorkspaceViewModel, ImportViewModel
├── Views/
│   ├── Landing/
│   ├── Projects/
│   ├── Workspace/         Import, Media, Setup, Analysis, Storyboard tabs
│   └── Components/        MSDesignSystem, AssetThumbnailView, ConfidenceBadge
└── MockData/              MockDataProvider
```

---

## Entitlements required

- App Sandbox
- Photos Library (read-write)
- File Access → Downloads Folder (read-write, for export temp files)

Add these in Xcode: Target → Signing & Capabilities → `+`.
