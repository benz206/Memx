# MemX

A macOS 26 SwiftUI app that turns your Photos library into a cinematic memory montage, beat-synced to a song. Audio analysis and final stitching run on the Mac; visual scoring, captions, and semantic preparation are outsourced to OpenRouter.

The pipeline is three tabs, in order: **Song → Photos → Storyboard**. Drop in an audio file, pick your photos, run the pipeline, render an MP4.

---

## Highlights

- **OpenRouter visual orchestration** — downscaled representative frames go to OpenRouter for quality, emotion, novelty, captions, semantic summaries, and edit-use metadata.
- **Beat-synced sequencing** — song energy arc, section detection, onset grid, and mood arc drive clip duration, ordering, and transition choice.
- **Real render** — `AVMutableComposition` + `AVAssetExportSession` produces an actual MP4 at the end. Song is mixed in; clips are exported, stitched, and persisted.
- **Local stitching** — the Mac handles Photos access, audio beat analysis, and the final AVFoundation MP4 render.
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
   Song import            Photo import                  Storyboard + render
┌──────────────────┐   ┌──────────────────┐      ┌─────────────────────┐
│ AVAudioFile      │   │ PhotosPicker +   │      │ SequencerService    │
│ stream → mono    │   │ PHCachingImage-  │      │ builds beat-aligned │
│ 22.05 kHz        │   │ Manager          │      │ sequence            │
│                  │   │                  │      │                     │
│ vDSP autocorr    │   │ OpenRouter       │      │ AVMutableComposition│
│ BPM detection    │   │ visual scoring   │      │ + AVAssetExport-    │
│                  │   │                  │      │ Session → .mp4      │
│ Onset + section  │   │ Bounded Task-    │      │ Story ramp drives   │
│ detection        │   │ Group            │      │ clip density        │
└──────────────────┘   └──────────────────┘      └─────────────────────┘
   BeatmapService         PhotoScoringService      SequencerService +
                          VideoAnalysisService     VideoRenderService
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

- Fetches a downscaled photo or one representative video frame, JPEG-compresses it, and sends it to OpenRouter.
- OpenRouter returns strict storyboard metadata: `qualityScore`, `emotionScore`, `noveltyScore`, `eventLabel`, `sceneLabels`, `sceneCaption`, `semanticSummary`, `shotType`, warmth, face estimate, and best video start.
- Runs in a bounded `withThrowingTaskGroup`; preserves input order via an indexed result struct.
- Falls back to lightweight metadata heuristics when the API key or model call is unavailable, so development still works offline.

### Video analysis (`VideoAnalysisService`)

- The old local Vision video scorer is now a compatibility facade.
- Real video prep lives in `PhotoScoringService`: one representative frame plus metadata is sent to OpenRouter, and final source clipping still happens locally during render.

### Sequencer + render (`SequencerService`, `VideoRenderService`)

- Sequencer builds a story ramp: readable regular cuts at the start, tighter pre-chorus/buildup pacing, and denser clip coverage on drops or late choruses.
- Hook repeats reuse signature assets for déjà-vu/payoff, while semantic summaries and embeddings bias clip choice toward the requested vibe and song section.
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

- **Privacy Settings** — accessible behind a gear icon on the Landing view. Shows that OpenRouter handles AI orchestration while the Mac handles media access and stitching.
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

- Visual analysis, captions, and embeddings call OpenRouter using `OPENROUTER_API_KEY` or the matching UserDefaults key.
- Drag-dropped audio files wrap their `FileManager.copyItem` with `startAccessingSecurityScopedResource()` / `stop…`.
- The app builds as a SwiftPM executable (`swift run MemX`, or open `Package.swift` in Xcode); it is unsigned and dev-only. `Resources/MemX.entitlements` (App Sandbox + Hardened Runtime) applies only once it is wrapped in a signed Xcode app target.

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
         PhotoScoringService     OpenRouter visual analysis + lightweight media prep
         VideoAnalysisService    Compatibility facade
         SequencerService        Story-ramp storyboard builder
         VideoRenderService      AVMutableComposition + AVAssetExportSession (3-way)
              ↓
         ProjectStore         ~/Library/Application Support/MemX/projects.json
```

All services are protocol-based singletons and can be swapped under the `WorkspaceViewModel.init` defaults — the test suite exercises this via mock implementations.

---

## Project Structure

```
Sources/MemX/
├── App/                   MemXApp.swift, ContentView.swift
├── Models/                Project, MediaAsset, MontagePlan, AnalysisModels, Beatmap, SongTrack
├── Services/              PhotosLibraryService, AnalysisService (PhotoScoringService),
│                          BeatmapService, VideoAnalysisService, VideoRenderService,
│                          MontagePlannerService (SequencerService),
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

- Optional 2.5D parallax / Ken Burns rendering on stills
- Core Image transitions between clips (the render step list tags these "Coming soon")
- MusicKit integration for the mock song catalog
- EDL and PDF shot-list exports (UI is wired, formats TBD)
- Renamed status lifecycle (`draft → configuring → analyzing → ready → rendered`)

See `CLAUDE.md` for contributor notes.
