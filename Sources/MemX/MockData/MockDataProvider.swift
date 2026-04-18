import Foundation

// MARK: - MockDataProvider
// Provides seed data for previews and demo mode.

enum MockDataProvider {

    // MARK: - Projects

    static func demoProject() -> Project {
        var p = Project(
            id: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000001")!,
            title: "Summer in Lisbon",
            settings: MontageSettings(
                vibe: .travel,
                focus: .friends,
                aspectRatio: .widescreen,
                renderQuality: .parallax2D
            )
        )
        p.assetIDs = mockAssets().map(\.id)
        p.songTrack = mockSongTrack()
        p.status = .ready
        p.montagePlan = demoMontagePlan(assets: mockAssets(), settings: p.settings, beatmap: mockBeatmap(duration: 214))
        return p
    }

    static func sampleProjects() -> [Project] {
        [
            demoProject(),
            {
                var p = Project(title: "Birthday Weekend")
                p.assetIDs = Array(mockAssets().prefix(12).map(\.id))
                p.songTrack = SongTrack(
                    title: "Riptide",
                    artist: "Vance Joy",
                    fileURL: URL(fileURLWithPath: "/mock/riptide.mp3"),
                    durationSeconds: 204,
                    fileFormat: "mp3"
                )
                p.status = .draft
                return p
            }(),
            {
                var p = Project(
                    title: "Winter Cabin Trip",
                    settings: MontageSettings(vibe: .nostalgic, aspectRatio: .widescreen)
                )
                p.status = .analyzing
                p.assetIDs = Array(mockAssets().prefix(8).map(\.id))
                return p
            }(),
        ]
    }

    // MARK: - Song

    static func mockSongTrack() -> SongTrack {
        SongTrack(
            title: "Golden Thread",
            artist: "Novo Amor",
            fileURL: URL(fileURLWithPath: "/mock/golden-thread.mp3"),
            durationSeconds: 214,
            fileFormat: "mp3"
        )
    }

    // MARK: - Beatmap

    static func mockBeatmap(duration: Double = 214) -> Beatmap {
        let bpm = 72.0
        let beatInterval = 60.0 / bpm

        // Generate beat timestamps
        var beats: [Double] = []
        var t = 0.0
        while t < duration {
            beats.append(t)
            t += beatInterval
        }

        // Sections
        let sections: [BeatSection] = [
            BeatSection(type: .intro,     start: 0,    end: 15,   energyAvg: 0.12, cutStyle: .slowFade),
            BeatSection(type: .verse,     start: 15,   end: 46,   energyAvg: 0.38, cutStyle: .onBeat),
            BeatSection(type: .preChorus, start: 46,   end: 58,   energyAvg: 0.62, cutStyle: .accelerating),
            BeatSection(type: .chorus,    start: 58,   end: 90,   energyAvg: 0.82, cutStyle: .onBeat),
            BeatSection(type: .verse,     start: 90,   end: 120,  energyAvg: 0.40, cutStyle: .onBeat),
            BeatSection(type: .buildup,   start: 120,  end: 134,  energyAvg: 0.72, cutStyle: .accelerating),
            BeatSection(type: .drop,      start: 134,  end: 152,  energyAvg: 0.97, cutStyle: .rapidCut),
            BeatSection(type: .breakdown, start: 152,  end: 168,  energyAvg: 0.18, cutStyle: .singleHold),
            BeatSection(type: .chorus,    start: 168,  end: 196,  energyAvg: 0.85, cutStyle: .onBeat),
            BeatSection(type: .outro,     start: 196,  end: duration, energyAvg: 0.1, cutStyle: .kenBurnsDrift),
        ]

        // Energy curve (sampled at 5s intervals)
        var energyCurve: [EnergyPoint] = []
        for i in stride(from: 0, through: duration, by: 5) {
            let section = sections.first { $0.start <= i && i < $0.end }
            let base = section?.energyAvg ?? 0.3
            let jitter = Double.random(in: -0.04...0.04)
            energyCurve.append(EnergyPoint(time: i, energy: min(1, max(0, base + jitter))))
        }

        // Drops and vocal peaks
        let drops: [BeatMoment] = [
            BeatMoment(time: 134.0, intensity: 1.0),
            BeatMoment(time: 168.0, intensity: 0.87),
        ]
        let vocalPeaks: [BeatMoment] = [
            BeatMoment(time: 22.4, intensity: 0.55),
            BeatMoment(time: 65.0, intensity: 0.8),
            BeatMoment(time: 178.0, intensity: 0.9),
        ]

        return Beatmap(
            bpm: bpm,
            durationSeconds: duration,
            energyCurve: energyCurve,
            sections: sections,
            beats: beats,
            drops: drops,
            vocalPeaks: vocalPeaks
        )
    }

    /// Variant of `mockBeatmap` with two synthetic hook occurrences on the two
    /// chorus sections and a third occurrence mapped to the drop. The final
    /// hook occurrence has the highest repeatIndex so the anticipation hold
    /// has a well-defined target.
    static func mockBeatmapWithHooks(duration: Double = 214) -> Beatmap {
        var bm = mockBeatmap(duration: duration)

        // bm.sections[3] is the first chorus (58..90), bm.sections[8] is the
        // second chorus (168..196). Treat these as one hook cluster.
        func sig(in range: ClosedRange<Double>) -> [Double] {
            let step = (range.upperBound - range.lowerBound) / 5.0
            return (1...4).map { Double($0) * step + range.lowerBound }
        }

        let hooks: [HookMoment] = [
            HookMoment(
                startTime: 58, endTime: 90,
                repeatIndex: 0,
                signatureBeats: sig(in: 58...90),
                similarity: 0.82
            ),
            HookMoment(
                startTime: 168, endTime: 196,
                repeatIndex: 1,
                signatureBeats: sig(in: 168...196),
                similarity: 0.82
            ),
        ]
        bm.hooks = hooks
        return bm
    }

    // MARK: - Motion Prompts

    static func mockMotionPrompts(for assets: [MediaAsset]) -> [MotionPrompt] {
        let prompts = [
            "Slow push-in toward the horizon. Morning mist drifts left across the water.",
            "Subtle parallax drift right-to-left. Soft bokeh shimmer in the background. Hair moves gently.",
            "Gentle upward tilt. Clouds drift slowly. Warm light rakes across the surface.",
            "Ken Burns zoom-out, starting tight on the faces. Background falls into soft focus.",
            "Parallax depth: near branches drift left as sky holds steady behind.",
            "Slow push-in with subtle light flicker. Candlelight dances in the corner of the frame.",
            "Fast zoom-in on the center subject. Motion blur trails at the edges.",
            "Tilt up from foreground detail to open sky. The scene opens wide.",
            "Cross-frame parallax — figures shift right while background holds. Depth exaggerated.",
            "Hold on the laugh. Subtle zoom-in on the peak expression. Bokeh swells.",
        ]
        return assets.enumerated().map { i, asset in
            MotionPrompt(
                assetID: asset.id,
                prompt: prompts[i % prompts.count],
                isEdited: false,
                motionIntensity: Float.random(in: 0.2...0.9),
                status: .ready
            )
        }
    }

    // MARK: - Assets

    static func mockAssets() -> [MediaAsset] {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2024, month: 7, day: 12))!

        let names = [
            "IMG_4821", "IMG_4822", "IMG_4825", "VID_0031", "IMG_4830",
            "IMG_4831", "VID_0032", "IMG_4850", "IMG_4851", "IMG_4870",
            "IMG_4871", "VID_0033", "IMG_4890", "IMG_4891", "IMG_4900",
            "IMG_4901", "IMG_4910", "VID_0034", "IMG_4920", "IMG_4921"
        ]
        let mediaTypes: [MSMediaType] = [
            .photo, .photo, .photo, .video, .photo,
            .photo, .video, .photo, .photo, .photo,
            .photo, .video, .photo, .photo, .livePhoto,
            .photo, .photo, .video, .photo, .photo
        ]
        let durations: [TimeInterval] = [
            0, 0, 0, 14.2, 0,
            0, 8.6, 0, 0, 0,
            0, 22.1, 0, 0, 0,
            0, 0, 11.4, 0, 0
        ]

        return names.enumerated().map { i, name in
            var asset = MediaAsset(
                id: "mock-asset-\(i + 1)",
                mediaType: mediaTypes[i],
                creationDate: calendar.date(byAdding: .minute, value: i * 23 + i * 7, to: base),
                filename: "\(name).\(durations[i] > 0 ? "mov" : "jpg")",
                pixelWidth: i % 3 == 0 ? 1920 : 3024,
                pixelHeight: i % 3 == 0 ? 1080 : 4032,
                isFavorite: i % 5 == 0,
                duration: durations[i]
            )
            asset.analysisScore = Float.random(in: 0.5...0.98)
            asset.qualityScore  = Float.random(in: 0.6...1.0)
            asset.emotionScore  = Float.random(in: 0.5...1.0)
            asset.noveltyScore  = Float.random(in: 0.4...1.0)
            return asset
        }
    }

    // MARK: - Albums

    static func mockAlbums() -> [MSAlbum] {
        [
            MSAlbum(title: "Recents", count: 2847, type: .smartAlbum),
            MSAlbum(title: "Favorites", count: 312, type: .smartAlbum),
            MSAlbum(title: "Videos", count: 89, type: .smartAlbum),
            MSAlbum(title: "Live Photos", count: 445, type: .smartAlbum),
            MSAlbum(title: "Summer 2024", count: 134, type: .userAlbum),
            MSAlbum(title: "Lisbon Trip", count: 67, type: .userAlbum),
            MSAlbum(title: "Birthday 2024", count: 88, type: .userAlbum),
            MSAlbum(title: "Winter Cabin", count: 54, type: .userAlbum),
            MSAlbum(title: "Portraits", count: 210, type: .userAlbum),
        ]
    }

    // MARK: - Montage Plan

    static func demoMontagePlan(assets: [MediaAsset], settings: MontageSettings, beatmap: Beatmap) -> MontagePlan {
        let prompts = mockMotionPrompts(for: assets)
        let promptMap = Dictionary(uniqueKeysWithValues: prompts.map { ($0.assetID, $0) })
        let sortedAssets = assets.sorted { ($0.analysisScore ?? 0) > ($1.analysisScore ?? 0) }
        let transitions: [TransitionType] = [.fadeFromBlack, .crossfade, .hardCut, .crossfade, .hardCut,
                                              .flashWhite, .hardCut, .dissolve, .crossfade, .hardCut]

        var currentTime: TimeInterval = 0
        let clipDurations: [TimeInterval] = [4.5, 2.8, 2.8, 1.8, 3.2, 1.2, 1.2, 6.0, 2.5, 1.6]
        let sectionTypes: [SectionType] = [.intro, .verse, .verse, .chorus, .verse,
                                            .drop, .drop, .breakdown, .chorus, .outro]

        let sequence: [MontageSequenceItem] = sortedAssets.prefix(10).enumerated().map { i, asset in
            let dur = clipDurations[i % clipDurations.count]
            let transIn = transitions[i % transitions.count]
            let transOut: TransitionType = i == 9 ? .dissolve : .hardCut
            let item = MontageSequenceItem(
                position: i,
                assetID: asset.id,
                startTime: currentTime,
                endTime: currentTime + dur,
                transitionIn: transIn,
                transitionOut: transOut,
                motionPrompt: promptMap[asset.id]?.prompt ?? "",
                motionIntensity: promptMap[asset.id]?.motionIntensity ?? 0.5,
                beatAligned: i % 2 == 0,
                confidenceScore: asset.analysisScore ?? 0.8,
                sectionType: sectionTypes[i % sectionTypes.count],
                selectionReason: "sharp & well-exposed · beat-aligned"
            )
            currentTime += dur
            return item
        }

        let moodArc = beatmap.energyCurve.prefix(8).enumerated().map { i, pt in
            MoodPoint(
                position: pt.time / beatmap.durationSeconds,
                valence: 0.4 + pt.energy * 0.6,
                energy: pt.energy,
                label: beatmap.section(at: pt.time)?.type.rawValue ?? ""
            )
        }

        return MontagePlan(
            title: "Summer in Lisbon",
            settings: settings,
            sequence: Array(sequence),
            moodArc: Array(moodArc),
            excludedAssetIDs: Array(sortedAssets.dropFirst(10).map(\.id))
        )
    }

    // MARK: - Processing Status

    static func completedProcessingStatus(for project: Project) -> ProcessingStatus {
        var s = ProcessingStatus(projectID: project.id)
        s.phase = .complete
        s.progress = 1.0
        s.message = "Pipeline complete — storyboard ready"
        s.completedAt = Date()
        return s
    }
}
