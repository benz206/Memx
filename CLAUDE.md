# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                                          # Build the package
swift run MemX                                       # Run the app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  # Run tests
```

`swift test` must be prefixed with `DEVELOPER_DIR` because XCTest is only available from Xcode, not Command Line Tools. Build and run benefit from the same `DEVELOPER_DIR` prefix when the Xcode 26 toolchain isn't selected system-wide (`xcode-select -s /Applications/Xcode.app/Contents/Developer`).

The app is opened in Xcode via the `.swiftpm` wrapper. There are **no third-party SPM dependencies**. Apple frameworks: Photos, PhotosUI, AVFoundation, AppKit, SwiftUI, Vision, Accelerate, NaturalLanguage. The entire pipeline — analysis, embeddings, sequencing, rendering — runs on-device with no network calls.

## Platform

- **macOS 26+ (Tahoe)** is the minimum deployment target — `AVVideoComposition.Configuration` (et al.) and a handful of SwiftUI affordances require it.
- `swift-tools-version: 6.2`, `swiftLanguageModes: [.v5]`. Swift 5 language mode is intentional: it keeps strict-concurrency warnings from cascading across the existing SwiftUI `Task { }` sites.

## Package Structure

Three targets:
- **`MemXCore`** (`Sources/MemX/`) — library with all models, services, views, and ViewModels.
- **`MemX`** (`Sources/MemXApp/`) — thin executable that calls `MemXApp.main()`.
- **`MemXTests`** (`Tests/MemXTests/`) — XCTest suite.

## What This Is

**MemX** is a macOS 26 SwiftUI app that turns a user's Photos library into a cinematic music video montage. It imports a song and a set of photos/videos, analyzes the track locally (BPM, sections, onsets, repeating hooks), scores the visuals on-device (metadata heuristics + Vision/NLEmbedding embeddings), and assembles a beat-synchronized storyboard that a real `AVFoundation` render pipeline turns into an MP4.

## Architecture

### Layer Overview

```
App (MemXApp + ContentView)
  └── ViewModels (@Observable) ── Services (Singletons)
        └── Views                    └── Models (Structs/Enums)
```

### State Management

Uses the `@Observable` macro (Swift 5.9+). Three ViewModels:

- **`AppViewModel`** — global project list, navigation state (`landing → projects → workspace(Project)`), Photos permission, on-disk persistence via `ProjectStore`.
- **`WorkspaceViewModel`** — open-project state: song/beatmap, assets, montage plan, render state, clip-shortage preflight, cancellation, pipeline log.
- **`ImportViewModel`** — import tab: album browsing, asset selection, filtering/sorting, PhotosPicker integration.

### Services (singletons)

- **`PhotosLibraryService`** — PhotoKit wrapper; `PHCachingImageManager` + `ThumbnailCache` (MainActor singleton) + `PHAssetCache`; falls back to mock data when permissions are denied. Album counts use `estimatedAssetCount` (full fetch only when PhotoKit reports NSNotFound).
- **`BeatmapService`** — real `AVAudioFile` + `vDSP` audio analysis. Downsamples to mono 22 kHz, builds an RMS envelope, estimates BPM via autocorrelation (capped at the first ~90s of envelope for speed), detects onsets via positive energy flux on the envelope, segments the track into sections (intro / verse / preChorus / chorus / drop / buildup / bridge / breakdown / outro), and clusters repeating chorus/drop sections into `HookMoment`s using an 8-dim envelope fingerprint + cosine similarity.
- **`PhotoScoringService`** (in `AnalysisService.swift`) — fully on-device: fetches one representative frame per asset, computes a Vision FeaturePrint (`visualEmbedding`) for match-cut continuity plus a real `colorTemperature` (red/blue balance of a 16×16 downsample; drives warmth matching and the color-jump crossfade trigger), and derives heuristic scores from asset metadata (`qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`, `motionEnergy`; `sceneCaption`/`semanticSummary` stay empty — the storyboard falls back to basic asset facts). Concurrency scales with `ScoringDensity`.
- **`SemanticEmbeddingService`** — `NLEmbedding`-based local sentence embeddings (`semanticEmbedding`) built from asset metadata, with a hashed-bag fallback when the embedding model asset is unavailable.
- **`SequencerService`** (in `MontagePlannerService.swift`) — builds the `MontagePlan` from beatmap + scored assets. Hook-aware (see below). Exposes a `preflight(...)` call so the UI can warn before building.
- **`VideoRenderService`** — real `AVMutableComposition` stitching on two alternating A/B video tracks so adjacent clips overlap. Every clip is placed at its plan `startTime` (song timeline) so cuts stay beat-locked. Storyboard transitions are rendered for real via `AVVideoCompositionLayerInstruction.Configuration` opacity/transform ramps, eased by sampling smooth curves at interior knots (AVFoundation lerps between them): smoothstep crossfade (outgoing held at 1.0 — the only exact cross-dissolve on stacked tracks), slower bloom-in dissolve, flash-white shaped as a late-rising incoming vs fast-dropping outgoing over a white background, ease-out whip-pan push, fade-from-black, plus Ken Burns drift and beat punch-ins on photos. Beat-synced brightness pulses (JBL-style: snap to full brightness on the beat, decay to a dimmed floor scaled by beat strength, gated by section) are emitted as sub-ramps within each instruction and multiplied into every active layer; the dip reveals a dark section-derived background tint, so hue moves only at section boundaries. Pure timing/motion/easing/pulse math lives in `RenderTimeline.swift`, unit-tested. Output via `AVAssetExportSession`.

### Key Models

- **`Project`** — root container; status flows `draft → configuring → importing → analyzing → ready → exported`. `MontageSettings` includes `scoringDensity` (decoded with `decodeIfPresent` for backward compatibility with older saved projects).
- **`ScoringDensity`** (`verySparse / sparse / balanced / dense / veryDense`) — controls service concurrency. `balanced` is the default.
- **`MediaAsset`** — wraps a `PHAsset`; post-analysis fields include `qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`, `sceneLabels: [String]?`, `sceneCaption: String?`, `semanticSummary: String?`, `motionEnergy: Float?` (0 still … 1 jumping/action; matched against audio energy in the sequencer), `semanticEmbedding: [Float]?` and `visualEmbedding: [Float]?`. The two embeddings are persisted as base64 Float32 blobs via custom Codable (legacy `[Float]` JSON still decodes).
- **`Beatmap`** — BPM, duration, energy curve, `[BeatSection]`, `[Double]` beats, drops/vocal peaks, `phraseStarts`, `beatStrengths`, and `hooks: [HookMoment]`.
- **`HookMoment`** — `startTime`, `endTime`, `repeatIndex` (chronological order within the cluster), `signatureBeats` (4 strongest beats), `similarity` (max cosine to a cluster-mate).
- **`MontagePlan`** — final storyboard: `[MontageSequenceItem]`, `moodArc`. Sequence items carry `isHookMoment`, `isAnticipationHold`, `hookRepeatIndex`, and a `GradingHint` (vibe + section-aware color grading suggestion; shown in the storyboard and used to bias the render's section background tint).

### Analysis Pipeline

`WorkspaceViewModel.runPipeline()` orchestrates; each service reports progress via a `(Double, String)` callback that the view-model splits into a global 0.0–1.0 range:

1. `analyzeAudio` → `BeatmapService`
2. `scorePhotos` → `PhotoScoringService` (on-device, bounded concurrency), then `SemanticEmbeddingService` for semantic embeddings
3. `buildSequence` → `SequencerService`. Preflighted first — if the plan would run out of unique clips, `clipShortfall` is populated and `pendingShortfallAck` gates the build until the user confirms (Add Photos / Build Anyway / Dismiss).

Analysis results are persisted on the project (`analyzedAssets`) so tab switches and relaunches don't repay analysis work.

### Sequencer / Emotional Edit Logic

`SequencerService` groups candidates by event cluster (to preserve narrative arc), then lays them out against the beatmap. Key behaviors:

- **Vibe-aware base cut patterns.** Nostalgic lengthens durations ×1.4 with softer transitions; hype emits sub-beat bursts in drops; cinematic favors on-beat match-cuts; balanced mixes pacing.
- **Hook anchoring (déjà vu).** The first occurrence of a hook cluster binds each signature-beat position to a specific asset. On repeat hooks, the sequencer force-reuses those assets at the same signature-beat offsets, creating a recall/payoff effect. Reused assets show a `⟲ Repeat` badge.
- **Anticipation hold.** One bar before the final chorus/drop, a single asset holds with a dissolve-in and flash-white-out, creating a moment of suspense.
- **Soft chronology.** Asset capture dates are rank-normalized to 0–1 and scored against each slot's position in the song (`chronologyFit`, weight 0.13), so the montage progresses forward in time overall while energy/semantic fit can reorder locally. Hook reuse bypasses this deliberately.
- **Grading hints.** Each slot carries a `GradingHint` derived from vibe × section type — surfaced in the storyboard detail panel as a micro-caption.
- **Selection-reason metadata.** Human-readable reasons populate `selectionReason` ("hook signature", "hook return", "anticipation hold", etc.) for the Why Selected card.

### Clip-Shortage Preflight

`SequencerPreflight` (returned by `SequencerService.preflight(settings:assets:beatmap:)`) reports `requiredClipCount`, `availableClipCount`, `estimatedShortfall`, `estimatedShortfallSeconds`. If `hasShortfall`, `WorkspaceViewModel` stores it on `clipShortfall` and sets `pendingShortfallAck` so the workspace can render a warning banner. The user either adds more photos, confirms "Build Anyway", or dismisses.

### Design System

`MSDesignSystem.swift` defines spacing/radius/typography tokens as nested enums (`MS.Spacing.md`, `MS.Radius.lg`, etc.), reusable SwiftUI components (`.msCard()`, `MSPrimaryButton`, `MSSecondaryButton`, `MSBadge`, `MSSkeletonBlock`, `MSGradientBackground`), and shared display mappings (`ProjectStatus.displayColor/.displayName`, `SectionType.displayColor`).

### Mock-First Development

`MockDataProvider` seeds mock assets, albums, beatmaps (including `mockBeatmapWithHooks`), and a completed processing status. Services fall back to mock output when Photos permission is denied, so development without library access stays productive.

## Known Integration Gaps

- **Music suggestions/MusicKit**: removed — users import their own song file.
- **Grading hints** only tint the render's section background (revealed by beat-pulse dips); `VideoRenderService` does not grade the footage itself (no LUT/curve path — layer instructions only support opacity + transform).
- **VLM scoring (OpenRouter)**: removed for now — scores are metadata heuristics, and `sceneCaption`/`semanticSummary` are never populated.
