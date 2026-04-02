# Memory Stitcher — Xcode Setup Guide

## Requirements
- macOS 14.0+ (Sonoma)
- Xcode 15.2+
- Swift 5.9+

---

### Step 1 — Create the project

1. Xcode → File → New → Project
2. Choose: **macOS → App**
3. Settings:
   - Product Name: `MemoryStitcher`
   - Team: your Apple ID / team
   - Bundle Identifier: `com.yourcompany.memorystitcher`
   - Interface: **SwiftUI**
   - Language: **Swift**
4. Save to any location

### Step 2 — Add source files

Drag all files from `Sources/MemoryStitcher/` into the Xcode project navigator.
Make sure "Copy items if needed" is **unchecked** (or checked if you want a copy).

Organize them into groups matching the folder structure:
- `App/`
- `Models/`
- `Services/`
- `ViewModels/`
- `Views/`
- `MockData/`

### Step 3 — Configure Info.plist

Add these keys to your Info.plist (or create one):

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Memory Stitcher accesses your Photos library to import photos and videos
for your montage project. All processing happens locally on your device.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>Memory Stitcher may save rendered montages back to your Photos library.</string>
```

### Step 4 — Configure Entitlements

1. Select your target → Signing & Capabilities
2. Click `+` → **App Sandbox**
3. Click `+` → **Photos Library** (read-write)
4. Under File Access → Downloads Folder: Read/Write (for export temp files)

Or copy `MemoryStitcher.entitlements` and set it as the entitlements file in Build Settings.

### Step 5 — Minimum Deployment Target

Target → General → Minimum Deployments → **macOS 14.0**

### Step 6 — Frameworks

The app uses these system frameworks (no manual linking needed with modern Xcode):
- `Photos`
- `PhotosUI`
- `AVFoundation`
- `SwiftUI`
- `Observation`

### Step 7 — Build & Run

Press `Cmd+R`. On first launch, the app will:
1. Show the landing screen with permission request
2. Fall back to mock data if Photos is denied (great for development)
3. Seed demo projects automatically

---

## Architecture Overview

```
MemoryStitcher/
├── App/                        # Entry point, root navigation
├── Models/                     # Pure value types (Codable, Hashable)
│   ├── Project.swift           # Project + MontageSettings + enums
│   ├── MediaAsset.swift        # MediaAsset, MSAlbum, ThumbnailCache
│   ├── MontagePlan.swift       # MontagePlan, MontageSequenceItem, SongSuggestion
│   └── AnalysisModels.swift    # MemoryEvent, AnalysisJobStatus, SceneSegment
├── Services/                   # Protocol-first, async/await
│   ├── PhotosLibraryService    # Real PhotoKit: permission, fetch, thumbnail, export
│   ├── AnalysisService         # Mocked AI pipeline (plug in Core ML here)
│   ├── MontagePlannerService   # Storyboard assembly logic
│   └── MusicSuggestionService  # Mood-matched soundtrack suggestions
├── ViewModels/                 # @Observable state, no UI imports
│   ├── AppViewModel            # Global navigation + project list
│   ├── ImportViewModel         # Import flow: albums, selection, picker
│   └── WorkspaceViewModel      # Per-project analysis + storyboard state
├── Views/
│   ├── Landing/                # Onboarding / hero screen
│   ├── Projects/               # Project list + row
│   └── Workspace/              # Per-project tabbed workspace
│       ├── Import/             # PhotoKit + PhotosPicker import flow
│       ├── Media/              # Sortable/filterable asset grid
│       ├── Setup/              # Montage settings configurator
│       ├── Analysis/           # AI pipeline progress + event clusters
│       └── Storyboard/         # Editable sequence, mood arc, soundtrack
├── Components/                 # Reusable UI atoms
│   ├── MSDesignSystem          # Tokens: radius, spacing, typography, shadows
│   ├── AssetThumbnailView      # PhotoKit thumbnail with caching
│   └── ConfidenceBadge         # Score rings, emotion badges, phase badges
└── MockData/
    └── MockDataProvider        # Seeded demo data for all models
```

---

## Where to Plug In Real AI

### Scene Detection
`AnalysisService.generateMockScenes()` → Replace with `Vision.VNGenerateAttentionBasedSaliencyImageRequest` or a Core ML model.

### Embeddings
`AnalysisService` Phase `.extractingEmb` → Load a CLIP-style Vision Transformer via `Core ML` (`MLModel`) and run `model.prediction(input:)` on each exported asset URL.

### Event Clustering
`AnalysisService.generateMockEvents()` → DBSCAN or K-Means over the embedding vectors from above.

### Moment Scoring
`AnalysisService.scoreAssets()` → Learned ranker model (quality × emotion × novelty) via Create ML regression or a fine-tuned tabular model.

### Music Matching
`MusicSuggestionService.suggestSongs()` → MusicKit API for licensed tracks, or nearest-neighbor search on a mood embedding space.

### Export / Render
`StoryboardView.renderPipelinePlaceholder` → `AVMutableComposition` + `AVVideoComposition` + `AVAssetExportSession`. The storyboard's `MontageSequenceItem` list already contains all the timing data needed to build the composition.
