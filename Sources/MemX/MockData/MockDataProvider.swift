import Foundation

// MARK: - MockDataProvider
// Provides seed data for previews and demo mode.

enum MockDataProvider {

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
            BeatSection(type: .intro,     start: 0,    end: 15,   energyAvg: 0.12),
            BeatSection(type: .verse,     start: 15,   end: 46,   energyAvg: 0.38),
            BeatSection(type: .preChorus, start: 46,   end: 58,   energyAvg: 0.62),
            BeatSection(type: .chorus,    start: 58,   end: 90,   energyAvg: 0.82),
            BeatSection(type: .verse,     start: 90,   end: 120,  energyAvg: 0.40),
            BeatSection(type: .buildup,   start: 120,  end: 134,  energyAvg: 0.72),
            BeatSection(type: .drop,      start: 134,  end: 152,  energyAvg: 0.97),
            BeatSection(type: .breakdown, start: 152,  end: 168,  energyAvg: 0.18),
            BeatSection(type: .chorus,    start: 168,  end: 196,  energyAvg: 0.85),
            BeatSection(type: .outro,     start: 196,  end: duration, energyAvg: 0.1),
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
