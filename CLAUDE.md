# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                                          # Build the package
swift run MemX                                       # Run the app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  # Run tests
```

`swift test` must be prefixed with `DEVELOPER_DIR` because XCTest is only available from Xcode, not Command Line Tools. Build and run benefit from the same `DEVELOPER_DIR` prefix when the Xcode 26 toolchain isn't selected system-wide (`xcode-select -s /Applications/Xcode.app/Contents/Developer`).

The app is opened in Xcode via the `.swiftpm` wrapper. Third-party SPM dependencies: **mlx-swift** and **mlx-swift-lm** (Apple ML Research, MIT-licensed; on-device VLM inference), **swift-huggingface** and **swift-transformers** (Hugging Face, Apache-2.0; model download and tokenisation). Apple frameworks: Photos, PhotosUI, AVFoundation, AppKit, SwiftUI, Vision, Accelerate, FoundationModels. All AI inference runs on-device — the only network use is a one-time download of the MLX VLM weights from Hugging Face on first launch (cached to `~/Library/Caches/huggingface`).

## Platform

- **macOS 26+ (Tahoe)** is the minimum deployment target — the Foundation Models framework, `AVVideoComposition.Configuration` (et al.), and a handful of SwiftUI affordances require it.
- `swift-tools-version: 6.2`, `swiftLanguageModes: [.v5]`. Swift 5 language mode is intentional: it keeps strict-concurrency warnings from cascading across the existing SwiftUI `Task { }` sites.

## Package Structure

Three targets:
- **`MemXCore`** (`Sources/MemX/`) — library with all models, services, views, and ViewModels.
- **`MemX`** (`Sources/MemXApp/`) — thin executable that calls `MemXApp.main()`.
- **`MemXTests`** (`Tests/MemXTests/`) — XCTest suite (227 tests as of this writing).

## What This Is

**MemX** is a macOS 26 SwiftUI app that turns a user's Photos library into a cinematic music video montage using on-device AI. It imports a song and a set of photos/videos, analyzes the track (BPM, sections, onsets, repeating hooks), scores the visuals with Vision, generates per-asset scene captions and cinematographer-style motion prompts (both via Apple Foundation Models running locally), and assembles a beat-synchronized storyboard that a real `AVFoundation` render pipeline turns into an MP4. All processing — audio analysis, photo scoring, captioning, motion prompt generation, and rendering — runs entirely on-device.

## Architecture

### Layer Overview

```
App (MemXApp + ContentView)
  └── ViewModels (@Observable) ── Services (Protocol + Singleton)
        └── Views                    └── Models (Structs/Enums)
```

### State Management

Uses the `@Observable` macro (Swift 5.9+). Three ViewModels:

- **`AppViewModel`** — global project list, navigation state (`landing → projects → workspace(Project)`), Photos permission, on-disk persistence via `ProjectStore`.
- **`WorkspaceViewModel`** — open-project state: song/beatmap, assets, motion prompts, montage plan, render state, clip-shortage preflight, cancellation.
- **`ImportViewModel`** — import tab: album browsing, asset selection, filtering/sorting, PhotosPicker integration.

### Services (all protocol-based singletons)

- **`PhotosLibraryService`** — PhotoKit wrapper; `PHCachingImageManager` + `ThumbnailCache` (MainActor singleton); falls back to mock data when permissions are denied.
- **`BeatmapService`** — real `AVAudioFile` + `vDSP` audio analysis. Downsamples to mono 22 kHz, builds an RMS envelope, estimates BPM via autocorrelation (capped at the first ~90s of envelope for speed), detects onsets via positive spectral flux, segments the track into sections (intro / verse / preChorus / chorus / drop / buildup / bridge / breakdown / outro), and clusters repeating chorus/drop sections into `HookMoment`s using an 8-dim envelope fingerprint + cosine similarity.
- **`PhotoScoringService`** (in `AnalysisService.swift`) — Vision-powered: face rectangles, attention-based saliency, and `VNClassifyImageRequest` labels. Emits `qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`, plus scene labels on each `MediaAsset`. Concurrency scales with `ScoringDensity`.
- **`VideoAnalysisService`** — samples N frames per video (N = `ScoringDensity.videoFrameSamples`, 8/14/20/30/48), scores each, and returns best-segment metadata.
- **`SceneCaptionService`** — Generates one-sentence evocative captions using `LocalVLMService`, which runs **Qwen2-VL-2B-Instruct (4-bit)** via MLX on Apple Silicon. The actual `CGImage` pixels are fed to the model; `sceneLabels` from Vision are appended as supplementary hint text. Times out at 20 s. Returns `nil` on error or timeout so the pipeline degrades gracefully.
- **`MotionPromptService`** — Apple Foundation Models (`SystemLanguageModel` + `LanguageModelSession`) for one-to-two-sentence cinematographer directions. Weaves `asset.sceneCaption` + `sceneLabels` into a text prompt. Falls back to a deterministic mock when the model is unavailable or times out (6s).
- **`SequencerService`** (in `MontagePlannerService.swift`) — builds the `MontagePlan` from beatmap + scored assets. Hook-aware (see below). Exposes a `preflight(...)` call so the UI can warn before building.
- **`MusicSuggestionService`** — matches songs to mood arc via vibe/genre/energy scoring; uses a hardcoded mock catalog.
- **`VideoRenderService`** — real `AVMutableComposition` stitching, Ken Burns over video-toolbox frames, transitions, and `AVAssetExportSession` output.

### Key Models

- **`Project`** — root container; status flows `draft → configuring → importing → analyzing → ready → exported`. `MontageSettings` now includes `scoringDensity` (decoded with `decodeIfPresent` for backward compatibility with older saved projects).
- **`ScoringDensity`** (`verySparse / sparse / balanced / dense / veryDense`) — controls `videoFrameSamples` and service concurrency. `balanced` is the default.
- **`MediaAsset`** — wraps a `PHAsset`; post-analysis fields include `qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`, `sceneLabels: [String]?`, and `sceneCaption: String?`.
- **`Beatmap`** — BPM, duration, energy curve, `[BeatSection]`, `[Double]` beats, drops/vocal peaks, `phraseStarts`, `beatStrengths`, and `hooks: [HookMoment]`.
- **`HookMoment`** — `startTime`, `endTime`, `repeatIndex` (chronological order within the cluster), `signatureBeats` (4 strongest beats), `similarity` (max cosine to a cluster-mate).
- **`MontagePlan`** — final storyboard: `[MontageSequenceItem]`, `moodArc`, `suggestedSongs`. Sequence items carry `isHookMoment`, `isAnticipationHold`, `hookRepeatIndex`, and a `GradingHint` (vibe + section-aware color grading suggestion).

### Analysis Pipeline

`WorkspaceViewModel` orchestrates the pipeline; each service reports progress via a `(Double, String)` callback that the view-model splits into a global 0.0–1.0 range:

1. `analyzeAudio` → `BeatmapService` (0.00 → 0.33)
2. `scorePhotos` → `PhotoScoringService` + `VideoAnalysisService` + `SceneCaptionService` (0.33 → 0.55)
3. `generateAllMotionPrompts` → `MotionPromptService` (0.55 → 0.77); runs **4-wide bounded concurrency** — throughput is bounded by on-device Foundation Models inference.
4. `buildSequence` → `SequencerService` (0.77 → 1.00). Preflighted first — if the plan would run out of unique clips, `clipShortfall` is populated and `pendingShortfallAck` gates the build until the user confirms (Add Photos / Build Anyway / Dismiss).

### Sequencer / Emotional Edit Logic

`SequencerService` groups candidates by event cluster (to preserve narrative arc), then lays them out against the beatmap. Key behaviors:

- **Vibe-aware base cut patterns.** Nostalgic lengthens durations ×1.4 with softer transitions; hype emits sub-beat bursts in drops; cinematic favors on-beat match-cuts; balanced mixes pacing.
- **Hook anchoring (déjà vu).** The first occurrence of a hook cluster binds each signature-beat position to a specific asset. On repeat hooks, the sequencer force-reuses those assets at the same signature-beat offsets, creating a recall/payoff effect. Reused assets show a `⟲ Repeat` badge.
- **Anticipation hold.** One bar before the final chorus/drop, a single asset holds with a dissolve-in and flash-white-out, creating a moment of suspense.
- **Grading hints.** Each slot carries a `GradingHint` (e.g. `teal_orange`, `warm_film`, `cool_night`) derived from vibe × section type — surfaced in the storyboard detail panel as a micro-caption.
- **Selection-reason metadata.** Human-readable reasons populate `selectionReason` ("hook signature", "hook return", "anticipation hold", etc.) for the Why Selected card.

### Clip-Shortage Preflight

`SequencerPreflight` (returned by `SequencerService.preflight(settings:assets:beatmap:)`) reports `requiredClipCount`, `availableClipCount`, `estimatedShortfall`, `estimatedShortfallSeconds`. If `hasShortfall`, `WorkspaceViewModel` stores it on `clipShortfall` and sets `pendingShortfallAck` so `StoryboardView` can render a warning banner. The user either adds more photos, confirms "Build Anyway", or dismisses.

### Design System

`MSDesignSystem.swift` defines spacing/radius/typography tokens as nested enums (`MS.Spacing.md`, `MS.Radius.lg`, etc.) and reusable SwiftUI components (`.msCard()`, `MSPrimaryButton`, `MSSecondaryButton`, `MSBadge`, `MSSkeletonBlock`, `MSGradientBackground`).

### Mock-First Development

`MockDataProvider` seeds sample projects, assets, events, songs, beatmaps (including `mockBeatmapWithHooks`), and motion prompts. Services fall back to mock output when permissions are denied or network-gated features are disabled, so development in the simulator or without API keys remains productive.

## Known Integration Gaps

- **MusicKit**: `MusicSuggestionService` still uses a hardcoded mock catalog. Real MusicKit integration is a follow-up.
- **Foundation Models image input**: resolved — `SceneCaptionService` now routes actual image pixels through `LocalVLMService` (MLX + Qwen2-VL-2B-Instruct-4bit) instead of the text-only `LanguageModelSession` path.
- **AVFoundation deprecations**: `AVMutableVideoCompositionInstruction` / `AVMutableVideoCompositionLayerInstruction` are deprecated in macOS 26 in favor of the `*.Configuration` types. The render pipeline still uses the old types (functional, with warnings). Migrating is cosmetic cleanup.
