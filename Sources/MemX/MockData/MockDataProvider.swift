import Foundation

// MARK: - MockDataProvider
// Provides seed data for previews and demo mode.

enum MockDataProvider {

    // MARK: - Projects

    static func demoProject() -> Project {
        var p = Project(
            id: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000001")!,
            title: "Summer in Lisbon 🌅",
            settings: MontageSettings(
                targetDuration: .sixty,
                vibe: .travel,
                focus: .friends,
                pacing: .balanced,
                aspectRatio: .widescreen,
                musicPreference: .indie
            )
        )
        p.assetIDs = mockAssets().map(\.id)
        p.status = .ready
        p.montagePlan = demoMontagePlan(assets: mockAssets(), settings: p.settings)
        return p
    }

    static func sampleProjects() -> [Project] {
        [
            demoProject(),
            {
                var p = Project(title: "Birthday Weekend 🎂")
                p.assetIDs = Array(mockAssets().prefix(12).map(\.id))
                p.status = .draft
                return p
            }(),
            {
                var p = Project(
                    title: "Winter Cabin Trip",
                    settings: MontageSettings(vibe: .nostalgic, pacing: .slow, musicPreference: .ambient)
                )
                p.status = .analyzing
                p.assetIDs = Array(mockAssets().prefix(8).map(\.id))
                return p
            }(),
        ]
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
        let events = [
            "Arrival & First Looks", "Arrival & First Looks", "Arrival & First Looks", "Arrival & First Looks",
            "Golden Hour Walk", "Golden Hour Walk", "Golden Hour Walk",
            "Group Laughs", "Group Laughs", "Group Laughs",
            "The Quiet In-Between", "The Quiet In-Between",
            "Peak Celebration", "Peak Celebration", "Peak Celebration", "Peak Celebration",
            "Farewell & Reflection", "Farewell & Reflection", "Farewell & Reflection", "Farewell & Reflection"
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
            asset.eventLabel    = events[min(i, events.count - 1)]
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

    // MARK: - Events

    static func mockEvents() -> [MemoryEvent] {
        let assets = mockAssets()
        let assetChunks = [
            Array(assets[0..<4]),
            Array(assets[4..<7]),
            Array(assets[7..<10]),
            Array(assets[10..<12]),
            Array(assets[12..<16]),
            Array(assets[16..<20])
        ]
        let defs: [(String, String, Emotion)] = [
            ("Arrival & First Looks", "The opening moments — fresh, anticipatory, full of energy.", .excitement),
            ("Golden Hour Walk", "Late afternoon light catches everything beautifully.", .awe),
            ("Group Laughs", "Unscripted candid moments between friends.", .humor),
            ("The Quiet In-Between", "Softer, slower beats — a breath in the story.", .calm),
            ("Peak Celebration", "The moment everyone came for. Energy at its highest.", .joy),
            ("Farewell & Reflection", "Winding down — nostalgic and warm.", .nostalgia)
        ]
        return defs.enumerated().map { i, def in
            var event = MemoryEvent(
                label: def.0,
                description: def.1,
                assetIDs: assetChunks[i].map(\.id),
                dominantEmotion: def.2,
                importanceScore: Float.random(in: 0.65...0.98)
            )
            event.representativeAssetID = assetChunks[i].first?.id
            return event
        }
    }

    // MARK: - Montage Plan

    static func demoMontagePlan(assets: [MediaAsset], settings: MontageSettings) -> MontagePlan {
        let transitions: [TransitionType] = [.dip, .cut, .cut, .crossDissolve, .cut, .swipe, .cut, .cut, .crossDissolve, .cut]
        let reasons = [
            "sharp & well-exposed · strong emotional valence · 2 faces detected",
            "dynamic motion · visually distinct from neighbors",
            "well-exposed · nostalgic warmth in color palette",
            "cinematic framing · leading lines · golden hour light",
            "peak emotional moment · highest smile score in set",
            "dynamic motion · visually distinct · 3 faces detected",
            "calm counterpoint · balanced score across quality metrics",
            "sharp & well-exposed · strong emotional valence",
            "playful energy · unique perspective · humor detected",
            "closing emotional beat · nostalgia spike · farewell gesture"
        ]
        let pickedAssets = Array(assets.sorted { ($0.analysisScore ?? 0) > ($1.analysisScore ?? 0) }.prefix(10))
        var currentTime: TimeInterval = 0

        let sequence: [MontageSequenceItem] = pickedAssets.enumerated().map { i, asset in
            let dur = i % 3 == 0 ? 3.2 : (i % 3 == 1 ? 2.4 : 1.8)
            let trans = transitions[i % transitions.count]
            let item = MontageSequenceItem(
                position: i,
                assetID: asset.id,
                clipStart: 0,
                clipEnd: asset.isVideo ? min(asset.duration, dur) : dur,
                transitionType: trans,
                eventLabel: asset.eventLabel ?? "Scene \(i+1)",
                selectionReason: reasons[i % reasons.count],
                beatAligned: i % 2 == 0,
                confidenceScore: asset.analysisScore ?? 0.8,
                estimatedFinalStart: currentTime,
                estimatedFinalEnd: currentTime + dur
            )
            currentTime += dur + trans.defaultDuration
            return item
        }

        return MontagePlan(
            title: "Summer in Lisbon 🌅",
            settings: settings,
            sequence: sequence,
            suggestedSongs: mockSongs(),
            moodArc: mockMoodArc()
        )
    }

    static func mockSongs() -> [SongSuggestion] {
        [
            SongSuggestion(title: "Golden Thread", artist: "Novo Amor", genre: .indie, bpm: 72, durationSeconds: 214, moodTags: ["warm","nostalgic"], vibeMatch: 0.94, energyLevel: 0.28),
            SongSuggestion(title: "Riptide", artist: "Vance Joy", genre: .indie, bpm: 104, durationSeconds: 204, moodTags: ["playful","adventure"], vibeMatch: 0.81, energyLevel: 0.62),
            SongSuggestion(title: "All I Want", artist: "Kodaline", genre: .indie, bpm: 77, durationSeconds: 261, moodTags: ["emotional","love"], vibeMatch: 0.88, energyLevel: 0.38),
        ]
    }

    static func mockMoodArc() -> [MoodPoint] {
        [
            MoodPoint(position: 0.0,  valence: 0.6, energy: 0.5,  label: "Arrival"),
            MoodPoint(position: 0.2,  valence: 0.75, energy: 0.65, label: "Golden Hour"),
            MoodPoint(position: 0.4,  valence: 0.9,  energy: 0.8,  label: "Group Laughs"),
            MoodPoint(position: 0.55, valence: 0.5,  energy: 0.3,  label: "Quiet Moment"),
            MoodPoint(position: 0.72, valence: 0.95, energy: 0.95, label: "Peak Celebration"),
            MoodPoint(position: 0.9,  valence: 0.7,  energy: 0.35, label: "Farewell"),
            MoodPoint(position: 1.0,  valence: 0.65, energy: 0.2,  label: "Fade Out"),
        ]
    }

    // MARK: - Analysis Status

    static func completedAnalysisStatus(for project: Project) -> AnalysisJobStatus {
        var s = AnalysisJobStatus(projectID: project.id)
        s.phase = .complete
        s.progress = 1.0
        s.message = "Analysis complete — storyboard ready"
        s.completedAt = Date()
        return s
    }
}
