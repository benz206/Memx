# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                                          # Build the package
swift run MemX                                       # Run the app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  # Run tests
```

`swift test` must be prefixed with `DEVELOPER_DIR` because XCTest is only available from Xcode, not Command Line Tools.

The app is opened in Xcode via the `.swiftpm` wrapper. No external dependencies — only Apple frameworks (Photos, PhotosUI, AVFoundation, AppKit, SwiftUI).

## Package Structure

The package has three targets:
- **`MemXCore`** (`Sources/MemX/`) — library with all models, services, views, and ViewModels
- **`MemX`** (`Sources/MemXApp/`) — thin executable that calls `MemXApp.main()`
- **`MemXTests`** (`Tests/MemXTests/`) — XCTest suite (192 tests)

## What This Is

**MemX** is a macOS 14+ SwiftUI app that turns a user's Photos library into a cinematic memory montage using on-device AI. It imports photos/videos, analyzes them, clusters moments into narrative events, scores content, and assembles a storyboard with transitions and soundtrack suggestions. All processing is local.

## Architecture

### Layer Overview

```
App (MemXApp + ContentView)
  └── ViewModels (Observable) ── Services (Protocol + Singleton)
        └── Views                    └── Models (Structs/Enums)
```

### State Management

Uses the `@Observable` macro (Swift 5.9 / iOS 17+) — no `@Published` needed. Three ViewModels:

- **`AppViewModel`** — global project list, navigation state (`landing → projects → workspace(Project)`), Photos permission, UserDefaults persistence
- **`WorkspaceViewModel`** — open project state: assets, analysis status, montage plan, storyboard editing
- **`ImportViewModel`** — import tab: album browsing, asset selection, filtering/sorting, PhotosPicker integration

### Services (all protocol-based singletons)

- **`PhotosLibraryService`** — PhotoKit wrapper; uses `PHCachingImageManager` + `ThumbnailCache` (MainActor singleton); falls back to mock data when permissions are denied
- **`AnalysisService`** — fully mocked AI pipeline with realistic delays; ready for Core ML integration (hooks are in place with TODO comments)
- **`MontagePlannerService`** — converts `AnalysisResult` into a `MontagePlan`; groups clips by event cluster to preserve narrative arc, then adjusts clip durations based on pacing and score
- **`MusicSuggestionService`** — matches songs to mood arc via vibe/genre/energy scoring; uses a hardcoded mock catalog

### Key Models

- **`Project`** — root container; status flows `draft → importing → analyzing → ready → exported`
- **`MediaAsset`** — wraps a PHAsset; carries post-analysis scores (`qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`)
- **`MontagePlan`** — final storyboard: `[MontageSequenceItem]`, `moodArc`, `suggestedSongs`
- **`AnalysisResult`** — output of analysis pipeline: `[MemoryEvent]`, `[SceneSegment]`, `[ClipCandidate]`

### Analysis Pipeline (mocked)

`WorkspaceViewModel.runAnalysis()` calls `AnalysisService` through 8 phases:
`loadingAssets → detectingScenes → extractingEmbeddings → clusteringEvents → scoringMoments → selectingSong → buildingStoryboard → complete`

Each phase reports progress via a callback. After completion, `generatePlan()` calls `MontagePlannerService` then `MusicSuggestionService`.

### Narrative Flow Algorithm

`MontagePlannerService` groups candidates by event, picks top-3 from each event (preserving emotional arc), then adjusts clip durations:
- Slow pacing: ~4.5s/clip, crossDissolve/dip transitions
- Balanced: ~2.8s/clip, varied transitions
- Energetic: ~1.6s/clip, cut/flash transitions
- Score >0.85 → +40% duration; score <0.55 → -30%

### Design System

`MSDesignSystem.swift` defines all spacing/radius/typography tokens as nested enums (`MS.Spacing.md`, `MS.Radius.lg`, etc.) and reusable ViewModifiers (`.msCard()`, `MSPrimaryButton`, `MSSecondaryButton`, `MSBadge`, `MSSkeletonBlock`).

### Mock-First Development

`MockDataProvider` seeds sample projects, assets, events, and songs. All services return mock data when Photos permission is denied, making development/simulator work possible without real library access.

## Pending Integration Points

The ML/AI layer is mocked throughout with explicit TODO comments:
- `AnalysisService`: Replace with Core ML vision embeddings (CLIP-style transformer), real face/emotion detection
- `MusicSuggestionService`: Replace mock catalog with MusicKit
- `PhotosLibraryService.exportAssetForProcessing()`: Connect exported files to the ML pipeline
- Rendering: `AVMutableComposition` stitching, Core Image transitions, `AVAssetExportSession` output — not yet implemented
