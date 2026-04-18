# MemX

A macOS 26 SwiftUI app that turns your Photos library into a cinematic memory montage, beat-synced to a song. Analysis, scoring, motion planning, and render all run entirely on-device using Apple frameworks.

The pipeline is four tabs, in order: **Song → Photos → Motion → Storyboard**. Drop in an audio file, pick your photos, run the pipeline, render an MP4.

---

## Highlights

- **Real on-device analysis** — Vision face/saliency/classify, `vDSP` autocorrelation BPM, AVFoundation frame scoring. No mock fallbacks behind the hood.
- **Beat-synced sequencing** — song energy arc, section detection, onset grid, and mood arc drive clip duration, ordering, and transition choice.
- **Real render** — `AVMutableComposition` + `AVAssetExportSession` produces an actual MP4 at the end. Song is mixed in; clips are exported, stitched, and persisted.
- **Privacy first** — everything runs on-device. No images, prompts, or analysis ever leave your Mac.
- **Non-blocking UI** — every service is `nonisolated` (no default `@MainActor` isolation) and heavy work runs in bounded `TaskGroup`s. You can cancel mid-pipeline and mid-render.
- **Project persistence** — projects are JSON-serialized to `~/Library/Application Support/MemX/projects.json` with atomic writes, and `PHAsset` references are restored when you reopen a project.

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.2+ / Swift 5.9+
- Photos library access (the app runs with mock data if denied, for simulator/dev work)

---

## Build & Run

```bash
git clone <repo>
cd Memx
swift build
swift run MemX
```

Or open `Package.swift` directly in Xcode and press `Cmd+R`. `swift test` requires `DEVELOPER_DIR` so XCTest resolves:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 192 tests
```

---

## The Pipeline

```
   Song import            Photo import           Motion prompts        Storyboard + render
┌──────────────────┐   ┌──────────────────┐   ┌───────────────────┐  ┌─────────────────────┐
│ AVAudioFile      │   │ PhotosPicker +   │   │ Per-asset prompt  │  │ SequencerService    │
│ stream → mono    │   │ PHCachingImage-  │   │ (Apple Foundation │  │ builds beat-aligned │
│ 22.05 kHz        │   │ Manager          │   │ Models, on-device)│  │ sequence            │
│                  │   │                  │   │                   │  │                     │
│ vDSP autocorr    │   │ Vision: face,    │   │ energy-aware text │  │ AVMutableComposition│
│ BPM detection    │   │ saliency,        │   │ describing motion │  │ + AVAssetExport-    │
│                  │   │ classify         │   │ per clip          │  │ Session → .mp4      │
│ Onset + section  │   │                  │   │                   │  │                     │
│ detection        │   │ Bounded Task-    │   │ 6s timeout, falls │  │ Mood arc drives     │
│                  │   │ Group (6-way)    │   │ back to heuristic │  │ transitions + dur.  │
└──────────────────┘   └──────────────────┘   └───────────────────┘  └─────────────────────┘
   BeatmapService         PhotoScoringService    MotionPromptService   SequencerService +
                          VideoAnalysisService                         VideoRenderService
```

Every phase reports progress through a callback, and every long-running phase is cancellable via a "Cancel" button in the sidebar footer.

---

## What's Under the Hood

### Audio analysis (`BeatmapService`)

- Streams source audio in **5-second windows** into an `AVAudioConverter` retargeted to **mono 22.05 kHz** — no more loading whole 10-minute tracks into RAM.
- `@preconcurrency import AVFoundation` so `AVAudioPCMBuffer` can cross the converter's `@Sendable` callback without warnings.
- BPM via `vDSP_vadd`/`vDSP_vsdiv` + autocorrelation on the mel-energy envelope.
- Onset detection, section clustering, and mood arc built in a **single O(n) two-pointer sweep** (previously O(n²) per-block filter).

### Photo scoring (`PhotoScoringService`)

- Vision requests per asset: `VNDetectFaceRectanglesRequest`, `VNGenerateAttentionBasedSaliencyImageRequest`, `VNClassifyImageRequest`.
- Runs in a **`withThrowingTaskGroup` bounded at 6 concurrent** per-asset analyses; preserves input order via an indexed result struct.
- Per-task "Starting N/total…" progress ticks so the bar never looks stuck while iCloud photos fetch.
- Fetches at **384 px `.opportunistic`** with a `resumed` guard that resolves on the non-degraded callback — fast enough for Vision, cheap enough for iCloud.

### Video analysis (`VideoAnalysisService`)

- Replaces deprecated `copyCGImage(at:actualTime:)` with `AVAssetImageGenerator.images(for:)` (AsyncSequence).
- Frames batched 6-wide, each batch runs the 3 Vision requests with `async let`.

### Motion prompts (`MotionPromptService`)

- Calls `SystemLanguageModel` + `LanguageModelSession` (Apple Foundation Models, macOS 26) entirely on-device.
- Builds a text prompt from `asset.sceneCaption`, `asset.sceneLabels`, song energy bucket, and section type.
- Races the model against a **6-second wall-clock timeout** via `withTaskGroup`; falls back to a deterministic heuristic prompt on timeout or model unavailability.
- Strips leading/trailing quotes from the model response.

### Sequencer + render (`SequencerService`, `VideoRenderService`)

- Sequencer groups candidates by event, picks top-3 per event to preserve the emotional arc, and adjusts clip durations against pacing + score (`>0.85` → +40%, `<0.55` → −30%).
- Render uses `AVMutableComposition.insertTimeRange` for each clip, attaches the audio track, and exports through `AVAssetExportSession`.
- Clip exports run in a **`TaskGroup` capped at 3 concurrent** (memory pressure from H.264 encoders is the real constraint).

### PhotoKit layer (`PhotosLibraryService`)

- `actor PHAssetCache` dedupes `PHAsset.fetchAssets(withLocalIdentifiers:)` calls across the app. A 300-asset project used to issue ~1500 PhotoKit fetches; now it's roughly one per distinct ID.
- `resolveAssets(for:)` batch-rehydrates a project's saved `assetIDs` back into `MediaAsset`s on workspace open — your photos come back when you reopen a project.
- `NSCache<NSString, NSImage>` thumbnail cache with a **256 MB `totalCostLimit`** (cost = `width × height × 4`). Was previously unbounded, could hit ~1.3 GB on a large library.
- Thumbnail fetch uses `.highQualityFormat` + `.exact` for crisp grid tiles; scoring uses `.opportunistic` + `.fast` for speed.
- All temp files are prefixed `memx-<uuid>.<ext>` and reaped by `cleanupTemporaryFiles()` on app launch and project close.

### Persistence (`ProjectStore`)

- Projects live as JSON at `~/Library/Application Support/MemX/projects.json` with atomic writes and ISO-8601 dates.
- One-shot migration on first launch: any legacy `UserDefaults.standard.data(forKey: "ms_projects")` is decoded, saved to disk, and the key is removed.
- `UserDefaults` is documented for <1 MB — a project with 300 clips + mood arc is well past that, so file-based storage is the right home.

### Concurrency model

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is **off**. Every service is `final class` with no implicit main-actor isolation, so Vision/AV/vDSP work never blocks the main thread.
- `ThumbnailCache` is the one `@MainActor` type, because it's UI-adjacent.
- Pipeline and render each own a `Task` handle; `cancelPipeline()` propagates through `Task.checkCancellation()` in every inner loop.

---

## UX & Flow

- **Privacy Settings** — accessible behind a gear icon on the Landing view. Confirms all AI runs on-device.
- **Step gating** — sidebar shows `checkmark.circle.fill` for completed steps, `circle.dotted` for the active one, `lock.fill` for unreachable. Navigating is never blocked; the lock is a cue, not a barrier.
- **Persistent pipeline runner** — "Run Pipeline" lives in the sidebar footer on every tab once `hasSong && !assets.isEmpty`, with a matching "Cancel" when a task is in flight.
- **Honest render steps** — the progress list shows what actually runs (clip stitch, audio attach, `AVAssetExportSession`). Planned items are tagged "Coming soon" instead of lying.
- **Confirmations** — "Replace existing render?" for re-render, "Leave project? Current pipeline will be cancelled." for back-nav during work, destructive delete moved behind a `⋯` menu with confirmationDialog.
- **Banners** — Photos-denied banner if authorization is missing; missing-assets banner if a reopened project's `PHAsset`s no longer exist; picker-error notice if a PhotosPicker ID can't be resolved.
- **Asset restore** — reopening a project re-hydrates all `PHAsset`s via a single batched fetch. If some are genuinely gone, the banner surfaces; we never silently swap in mock photos.

---

## Security & Sandbox

Entitlements (`Resources/MemX.entitlements`):

```
com.apple.security.app-sandbox                               true
com.apple.security.files.user-selected.read-write            true   # NSSavePanel + drag-drop
com.apple.security.personal-information.photos-library       true
com.apple.security.device.audio-input                        true   # future mic support
```

- All AI inference runs on-device — no network calls for analysis or prompts.
- Drag-dropped audio files wrap their `FileManager.copyItem` with `startAccessingSecurityScopedResource()` / `stop…`.
- App Sandbox + Hardened Runtime are both on for the Xcode target. (The `swift run` CLI binary is unsigned and dev-only; use Xcode for signed builds.)

---

## Architecture

```
MemXApp  →  ContentView
              ↓
         AppViewModel         (global nav, project list, ProjectStore)
              ↓
         WorkspaceViewModel   (per-project: assets, pipeline, render, cancellation)
         ImportViewModel      (album picker, PhotosPicker, filtered grid)
              ↓
         PhotosLibraryService    PhotoKit + PHAssetCache actor + ThumbnailCache NSCache
         BeatmapService          Streamed mono 22 kHz + vDSP BPM + onset/section
         PhotoScoringService     Vision face/saliency/classify (6-way TaskGroup)
         VideoAnalysisService    AsyncSequence frames + parallel Vision
         MotionPromptService     Apple Foundation Models on-device (6s timeout + mock fallback)
         SequencerService        Event-aware storyboard builder
         VideoRenderService      AVMutableComposition + AVAssetExportSession (3-way)
              ↓
         ProjectStore         ~/Library/Application Support/MemX/projects.json
```

All services are protocol-based singletons and can be swapped under the `WorkspaceViewModel.init` defaults — the 192-test suite exercises this via mock implementations.

---

## Project Structure

```
Sources/MemX/
├── App/                   MemXApp.swift, ContentView.swift
├── Models/                Project, MediaAsset, MontagePlan, AnalysisModels, Beatmap, MotionPrompt, SongTrack
├── Services/              PhotosLibraryService, AnalysisService (PhotoScoringService),
│                          BeatmapService, VideoAnalysisService, VideoRenderService,
│                          MotionPromptService, MontagePlannerService (SequencerService),
│                          MusicSuggestionService
├── ViewModels/            AppViewModel, WorkspaceViewModel, ImportViewModel
├── Persistence/           ProjectStore
├── Utilities/             (shared utilities)
├── Views/
│   ├── Landing/           LandingView (gear → Privacy)
│   ├── Projects/          ProjectsView
│   ├── Settings/          PrivacySettingsView
│   └── Workspace/         Import, Media, Setup, Analysis, Storyboard + WorkspaceView
├── Components/            MSDesignSystem, MSVerticalDivider, AssetThumbnailView, ConfidenceBadge
└── MockData/              MockDataProvider (tests only; not seeded for new users)
```

---

## Tests

192 XCTest cases covering models, persistence, scoring, sequencing, beatmap shape, and mock fixtures.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

---

## Roadmap

- 2.5D parallax / Ken Burns motion on stills
- Core Image transitions between clips (the render step list tags these "Coming soon")
- MusicKit integration for the mock song catalog
- EDL and PDF shot-list exports (UI is wired, formats TBD)
- Renamed status lifecycle (`draft → configuring → analyzing → ready → rendered`)

See `CLAUDE.md` for contributor notes.
