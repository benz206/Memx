import Foundation

// MARK: - BeatmapServiceProtocol

protocol BeatmapServiceProtocol {
    func analyzeSong(
        at url: URL,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> Beatmap
}

// MARK: - BeatmapService (mocked — ready for Accelerate/AVAudioEngine analysis)

final class BeatmapService: BeatmapServiceProtocol {

    static let shared = BeatmapService()
    private init() {}

    func analyzeSong(
        at url: URL,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> Beatmap {
        // TODO: Replace with real audio analysis:
        //   - AVAudioFile for loading
        //   - Accelerate vDSP for FFT / spectral flux
        //   - Onset detection for beat timestamps
        //   - RMS energy for energy curve
        //   - Structural segmentation for section detection

        onProgress(0.1, "Loading audio file...")
        try await Task.sleep(for: .milliseconds(500))

        onProgress(0.35, "Detecting beats and tempo...")
        try await Task.sleep(for: .milliseconds(900))

        onProgress(0.6, "Analyzing energy curve...")
        try await Task.sleep(for: .milliseconds(700))

        onProgress(0.85, "Identifying song sections...")
        try await Task.sleep(for: .milliseconds(500))

        onProgress(1.0, "Beatmap complete")

        // Derive mock duration from file if possible, else default
        let duration = estimatedDuration(for: url)
        return MockDataProvider.mockBeatmap(duration: duration)
    }

    private func estimatedDuration(for url: URL) -> Double {
        // AVAsset duration in a real implementation — return mock for now
        return 214
    }
}
