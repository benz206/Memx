# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                                          # Build the package
swift run MemX                                       # Run the app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  # Run tests
```

`swift test` must be prefixed with `DEVELOPER_DIR` because XCTest is only available from Xcode, not Command Line Tools. Build and run benefit from the same `DEVELOPER_DIR` prefix when the Xcode 26 toolchain isn't selected system-wide (`xcode-select -s /Applications/Xcode.app/Contents/Developer`).

The app is opened in Xcode via the `.swiftpm` wrapper. There are **no third-party SPM dependencies**. Apple frameworks: Photos, PhotosUI, AVFoundation, AppKit, SwiftUI, Vision, Accelerate, NaturalLanguage, FoundationModels, CoreImage. The entire pipeline — analysis, embeddings, sequencing, rendering — runs on-device with no network calls.

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

- **`AppViewModel`** — global project list, navigation state (`projects → workspace(Project)`; the app launches straight into the projects list), projects-list selection (`selectedProjectID`) and New Project sheet flag (both targeted by menu commands), Photos permission, on-disk persistence via `ProjectStore` (injectable; stale Songs/Exports cleanup is rooted at the store's directory, so tests pass a scratch store).
- **`WorkspaceViewModel`** — open-project state: song/beatmap, assets, montage plan, render state, clip-shortage preflight, cancellation, pipeline log. Holds a weak `activeImportVM` so Edit-menu commands can reach the photos grid.

Both view models are `@MainActor`, so every state transition is serialized.

### Explicit State Machines

Long-running workspace state lives in enums with a pure `next(on: Event) -> State?` transition table (nil = illegal; the view-model's `send`/`sendGate`/`sendRender` logs and ignores it). Never mutate these with ad hoc flags — add an event and a table row, and unit-test it (`PipelineStateTests`, `RenderStateTests`).

- **`PipelineState`** (`Models/PipelineState.swift`) — `idle / running(phase, progress, message) / awaitingShortfallAck / completed / failed(phase, …) / cancelled(phase, …)`. Phases only advance forward while running (late progress callbacks from an earlier phase are dropped); `complete` is legal only from `sequencing`; `reset` is refused while running. `isProcessing`, `isGeneratingPlan` are projections.
- **`ShortfallGate`** (same file) — `clear / warning(SequencerPreflight) / acknowledged`. Acknowledgement survives re-evaluation until inputs change (`reset` from `invalidateGeneratedOutputs`). `clipShortfall` is a projection.
- **`RenderState`** (`Models/RenderState.swift`) — `idle / rendering(progress, message) / finished(URL) / failed / cancelled`. `isRendering`, `renderProgress`, `renderProgressMessage`, `renderedVideoURL`, `renderError` are projections.
- **`AssetRestoreState`** — `idle / restoring / restored(missingCount:)`.
- **Pipeline and render are mutually exclusive**: neither starts (nor does song import) while the other runs.
- **`ImportViewModel`** — import tab: album browsing, asset selection, filtering/sorting, PhotosPicker integration.

### Menu Commands & Keyboard Shortcuts

Defined in `MemXApp.commands`, enabled/disabled from live view-model state (via `appViewModel.activeWorkspaceVM`, only while a workspace is open): ⌘N new project, ⌘R run pipeline, ⇧⌘E export video, ⌘. stop, ⌘[ back to projects, ⌘1–⌘4 workspace stages, ⇧⌘]/⇧⌘[ next/previous stage, ⇧⌘A/⇧⌘D select/deselect all assets. The projects list additionally handles Return (open) and Delete (confirm-delete); the storyboard sequence list handles Delete (remove clip).

### Services (singletons)

- **`PhotosLibraryService`** — PhotoKit wrapper; `PHCachingImageManager` + `ThumbnailCache` (MainActor singleton) + `PHAssetCache`; falls back to mock data when permissions are denied. Album counts use `estimatedAssetCount` (full fetch only when PhotoKit reports NSNotFound).
- **`BeatmapService`** — real `AVAudioFile` + `vDSP` audio analysis. Downsamples to mono 22 kHz, builds an RMS envelope, estimates BPM via autocorrelation (capped at the first ~90s of envelope for speed) with a log-Gaussian tempo prior around 120 BPM (resolves half/double-time) and parabolic lag refinement, detects onsets via positive energy flux on the envelope, lays a phase-locked beat grid (each predicted beat snaps to the strongest onset within ±12% of the period so tempo error stops compounding), estimates the downbeat by a 4-phase onset-strength vote (`Beatmap.downbeatIndex` anchors `barStarts`/`beatStrengths`/phrases), segments the track into sections (intro / verse / preChorus / chorus / drop / buildup / bridge / breakdown / outro) whose interior boundaries snap to bar starts and which carry a measured `onsetDensity`, picks drops/vocal peaks strongest-first with a minimum separation, and clusters repeating chorus/drop sections into `HookMoment`s using an 8-dim envelope fingerprint + cosine similarity. Logs grid-vs-onset mean error for tuning.
- **`PhotoScoringService`** (in `AnalysisService.swift`) — fully on-device: fetches one representative frame per asset and runs `visionReadout` — Vision aesthetics (`qualityScore`, `isUtility` for screenshots/receipts, floored out of the pool), image classification (precision-filtered → `sceneLabels`), face capture quality (`faceCount`, `faceAreaFraction`, shot type), and a `focusPoint` (faces, else attention saliency; normalized, top-left origin) used for render cropping. Also a Vision FeaturePrint (`visualEmbedding`) for match-cut continuity, burst dedup and novelty, plus a real `colorTemperature` (red/blue balance of a 16×16 downsample; drives warmth matching and the color-jump crossfade trigger). Pure score mappings live in `VisualSignals.swift` (unit-tested). After per-asset work, `applyPoolSignals` measures `noveltyScore` against the project's other embeddings and clusters `eventLabel`s by time/location gaps. Videos additionally get a 16-sample motion-over-time series (`motionSamples`, frame differencing of tiny grayscale frames) that overrides `motionEnergy` and powers cut-on-action in the sequencer. Results carry `analysisVersion` (`VisualSignals.analysisVersion`); only new or stale assets are re-analyzed. Concurrency scales with `ScoringDensity`.
- **`ShotUnderstandingService`** — on macOS 27+ with Apple Intelligence available and `ScoringDensity.usesShotUnderstanding` (balanced or denser), sends each non-utility frame plus its Vision labels to the on-device `SystemLanguageModel` (image `Attachment`, `@Generable` `ShotLog`, greedy sampling → deterministic). Fills `sceneCaption`, `semanticSummary` (mood · subjects), `mood`, `highlightScore`, and blends emotion/energy into `emotionScore` and photo `motionEnergy`. ~1 s per image; sessions serialize on-device. Silently skipped when unavailable.
- **`SemanticEmbeddingService`** — `NLEmbedding` sentence embeddings (`semanticEmbedding`) of caption + summary + labels + shot type (no dates/media-type tokens), with a hashed-bag fallback when the embedding model asset is unavailable.
- **`SequencerService`** (in `MontagePlannerService.swift`) — builds the `MontagePlan` from beatmap + scored assets. Hook-aware (see below). Exposes a `preflight(...)` call so the UI can warn before building.
- **`VideoRenderService`** — sources close to the canvas aspect (≥74% kept, `RenderTimeline.shouldFill`) fill the frame — photos crop around `focusPoint`, videos center-crop; far-off ratios sit over a blurred, dimmed copy of the photo instead of black bars. Real `AVMutableComposition` stitching on two alternating A/B video tracks so adjacent clips overlap. Every clip is placed at its plan `startTime` (song timeline) so cuts stay beat-locked. Storyboard transitions are rendered for real via `AVVideoCompositionLayerInstruction.Configuration` opacity/transform ramps, eased by sampling smooth curves at interior knots (AVFoundation lerps between them): smoothstep crossfade (outgoing held at 1.0 — the only exact cross-dissolve on stacked tracks), slower bloom-in dissolve, flash-white shaped as a late-rising incoming vs fast-dropping outgoing over a white background, ease-out whip-pan push, fade-from-black, plus Ken Burns drift (every third non-impact photo holds static) and beat punch-ins on photos. Visual cuts lead the beat by `RenderTimeline.cutLead` (40ms, audio untouched) and soft-transition overlaps are expressed in beats (1-beat crossfade, 2-beat dissolve, wall-clock caps). Slow-mo holds (`MontageSequenceItem.speedFactor` < 1) insert a shorter source range and `scaleTimeRange` it to screen duration. `MEMX_CLICK_TRACK=1` (or the `MemXClickTrack` default) overlays a debug metronome — accented downbeats — for verifying grid alignment by ear. Beat-synced brightness pulses (JBL-style: snap to full brightness on the beat, decay to a dimmed floor scaled by beat strength, gated by section) are emitted as sub-ramps within each instruction and multiplied into every active layer; the dip reveals a dark section-derived background tint, so hue moves only at section boundaries. Pure timing/motion/easing/pulse math lives in `RenderTimeline.swift`, unit-tested. Output via `AVAssetExportSession`.

### Key Models

- **`Project`** — root container; `status` is derived, not stored: no plan → `draft` (no song, no assets) / `configuring`; plan → `ready` / `exported` (has `exportedVideoURL`). `.analyzing` is live-only via `WorkspaceViewModel.displayStatus`. The derived value is still encoded under `status` so older builds can decode new files. `MontageSettings` includes `scoringDensity` (decoded with `decodeIfPresent` for backward compatibility with older saved projects).
- **`ScoringDensity`** (`verySparse / sparse / balanced / dense / veryDense`) — controls service concurrency, and whether on-device shot understanding runs (off for the two sparse levels). `balanced` is the default.
- **`MediaAsset`** — wraps a `PHAsset`; post-analysis fields include `qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`, `sceneLabels: [String]?`, `sceneCaption: String?`, `semanticSummary: String?`, `motionEnergy: Float?` (0 still … 1 jumping/action; matched against audio energy in the sequencer), `semanticEmbedding: [Float]?`, `visualEmbedding: [Float]?`, `analysisVersion`, `isUtility`, `faceCount`, `focusPoint`, `mood`, `highlightScore`. The two embeddings are persisted as base64 Float32 blobs via custom Codable (legacy `[Float]` JSON still decodes). `WorkspaceViewModel.restoreAssets` copies analysis fields field-by-field — add new ones there too.
- **`Beatmap`** — BPM, duration, energy curve, `[BeatSection]` (with `onsetDensity`), `[Double]` beats, drops/vocal peaks, `phraseStarts`, `beatStrengths`, `hooks: [HookMoment]`, and `downbeatIndex` (all new fields decode legacy JSON via `decodeIfPresent`).
- **`HookMoment`** — `startTime`, `endTime`, `repeatIndex` (chronological order within the cluster), `signatureBeats` (4 strongest beats), `similarity` (max cosine to a cluster-mate).
- **`MontagePlan`** — final storyboard: `[MontageSequenceItem]`, `moodArc`. Sequence items carry `isHookMoment`, `isAnticipationHold`, `hookRepeatIndex`, and a `GradingHint` (vibe + section-aware color grading suggestion; shown in the storyboard and used to bias the render's section background tint).

### Analysis Pipeline

`WorkspaceViewModel.runPipeline()` (and the storyboard's `buildSequence()`, which shares the same runner without switching tabs) drives `PipelineState` through one cancellable task, skipping steps whose output already exists; each service reports progress via a `(Double, String)` callback that the view-model splits into a global 0.0–1.0 range:

1. Audio (0–0.20) → `BeatmapService`, only if there's no beatmap
2. Scoring (0.20–0.85) → `PhotoScoringService` (on-device, bounded concurrency), then `SemanticEmbeddingService` for semantic embeddings, only if any asset is unscored or stale
3. Sequencing (0.85–1.0) → `SequencerService`. Gated by `ShortfallGate` first — if the plan would run out of unique clips the run pauses in `awaitingShortfallAck` until the user confirms (Add Photos / Build Anyway / Dismiss).

Any thrown error ends in `failed(phase:)` and stops the run; cancellation ends in `cancelled(phase:)`. Song import runs step 1 alone (`analyzeAudio(track:)` → `finishStep` back to `idle`).

Analysis results are persisted on the project (`analyzedAssets`) so tab switches and relaunches don't repay analysis work.

### Sequencer / Emotional Edit Logic

`SequencerService` groups candidates by event cluster (to preserve narrative arc), then lays them out against the beatmap. Key behaviors:

- **Vibe-aware base cut patterns.** Nostalgic lengthens durations ×1.4 with softer transitions; hype emits sub-beat bursts in drops; cinematic favors on-beat match-cuts; balanced mixes pacing. Patterns additionally scale with the section's measured `onsetDensity` (±35% from the song's weighted mean → faster/slower cuts).
- **Hero-first reservation.** Before chronological fill, priority slots (anticipation hold, chorus/drop openers with the final arc first, first-occurrence hook signatures, vocal/breath holds) claim assets from the full pool, so the standout clip lands on the drop instead of an early verse.
- **Flash budget.** Flash-white is capped at ~4 per video from a prioritized candidate list (drop entries, final chorus entry, hype hook returns, strongest hits) plus the anticipation hold's exit; chorus/drop interiors always hard-cut.
- **Cut on action.** Video in-points place the strongest feasible `motionSamples` moment on the slot's peak beat (`SequencerService.cutOnActionOffset`); anticipation/vocal holds on videos with enough footage play at 0.75× (`speedFactor`).
- **Hook anchoring (déjà vu).** The first occurrence of a hook cluster binds each signature-beat position to a specific asset. On repeat hooks, the sequencer force-reuses those assets at the same signature-beat offsets, creating a recall/payoff effect. Reused assets show a `⟲ Repeat` badge.
- **Anticipation hold.** One bar before the final chorus/drop, a single asset holds with a dissolve-in and flash-white-out, creating a moment of suspense.
- **Soft chronology.** Asset capture dates are rank-normalized to 0–1 and scored against each slot's position in the song (`chronologyFit`, weight 0.13), so the montage progresses forward in time overall while energy/semantic fit can reorder locally. Hook reuse bypasses this deliberately.
- **Grading hints.** Each slot carries a `GradingHint` derived from vibe × section type — surfaced in the storyboard detail panel as a micro-caption.
- **Content-aware selection.** Slot scoring weighs aesthetic quality; chorus/drop openers and the anticipation hold favor `highlightScore`; burst near-duplicates (FeaturePrint cosine ≥ 0.88, union-find groups per build) are penalized once any member is used; semantic fit blends keyword hits with cosine similarity between each asset's caption embedding and a section × vibe × focus intent sentence (`intentSentence`), min-max normalized across the pool.
- **Selection-reason metadata.** Human-readable reasons populate `selectionReason` ("hook signature", "hook return", "anticipation hold", etc.) for the Why Selected card.

### Clip-Shortage Preflight

`SequencerPreflight` (returned by `SequencerService.preflight(settings:assets:beatmap:)`) reports `requiredClipCount`, `availableClipCount`, `estimatedShortfall`, `estimatedShortfallSeconds`. It's evaluated into `ShortfallGate` twice: early (advisory, before scoring, if a beatmap exists — scores change the eligible pool) and authoritatively right before sequencing. While the gate is `warning` the workspace renders a banner. "Build Anyway" acknowledges (and resumes the run if it's paused; mid-run it's remembered); "Dismiss" clears the warning and, if paused, returns the pipeline to `idle`.

### Design System

`MSDesignSystem.swift` defines tokens as nested enums (`MS.Spacing`, `MS.Radius`, `MS.Height`, `MS.Font`), color roles in `MSColor`, reusable components, and shared display mappings (`ProjectStatus.displayColor/.displayName`, `SectionType.displayColor`). The house style matches the user's web projects (benny-dashboard, tag-vault, bTagScriptPlayground) — flat "Ramp-style" admin UI — with neutral light/dark-adaptive grays instead of their Catppuccin palette:

- **Color roles:** `canvas` (page) / `canvasDeep` (secondary sidebars) / `surface` (panels, bars) / `surface2` (hover, selected, neutral badge fill); hairlines `line` (structure) and `lineStrong` (control borders, dashed empty states); text ramp `inkBright` / `ink` / `inkMuted` / `inkFaint` carries the hierarchy. Accent (`Color.accentColor`) is reserved for focus, selection, progress and live state; status uses tinted badges (`color.opacity(0.12)`) + dots, never solid fills.
- **Components:** `.msCard()` = 12 pt-radius surface panel with a 1 pt `line` border, no shadow. `MSButtonStyle` (`.buttonStyle(.ms(.primary | .secondary | .ghost | .danger, size:))`, 30/26 pt) — primary is inverted foreground (black on light, white on dark), not the accent; `MSPrimaryButton`/`MSSecondaryButton` wrap it. `MSPageHeader` (24 pt title + muted subtitle + bottom-aligned actions), `MSStatStrip` (KPI cells divided inside one panel, tabular numbers), `MSPanelHeader` (44 pt panel title bar with count), `MSCallout` (tone dot + title + message), `MSBadge` (neutral or tinted pill, optional dot), `.msEyebrow()` (10.5 pt uppercase tracked label), `EmptyStateView` (dashed-border panel), `FlowRow` (wrapping layout), `.msPage(maxWidth:)` for centered scrolling pages.
- Numbers use `.monospacedDigit()`; machine values (timestamps, durations, logs) use `MS.Font.mono`. `MSGradientBackground` is (despite the legacy name) the plain `canvas` background.
- Keep native controls where they exist (`Table`, sidebar `List`, `Picker`, `Form` sheets, toolbars, search) and style the content around them.

### Mock-First Development

`MockDataProvider` seeds mock assets, albums, beatmaps (including `mockBeatmapWithHooks`), and a completed processing status. Services fall back to mock output when Photos permission is denied, so development without library access stays productive.

## Known Integration Gaps

- **Music suggestions/MusicKit**: removed — users import their own song file.
- **Grading hints** only tint the render's section background (revealed by beat-pulse dips); `VideoRenderService` does not grade the footage itself (no LUT/curve path — layer instructions only support opacity + transform).
- **Scene understanding below macOS 27** (or without Apple Intelligence, or at sparse scoring density): `sceneCaption`/`semanticSummary`/`highlightScore` stay empty and selection runs on Vision signals + keyword matching only. Changing `ScoringDensity` does not trigger re-analysis.
- **Portrait videos in landscape montages** stay pillarboxed (the blurred backdrop is photo-only; it is baked into the still frame).
