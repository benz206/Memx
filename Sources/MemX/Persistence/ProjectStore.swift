import Foundation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "store")

final class ProjectStore {
    static let shared = ProjectStore()

    private let fileURL: URL

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let memxDir = appSupport.appendingPathComponent("MemX", isDirectory: true)
        self.init(fileURL: memxDir.appendingPathComponent("projects.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var directory: URL { fileURL.deletingLastPathComponent() }

    func load() -> [Project]? {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Project].self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("projects.unreadable-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            logger.error("projects.json could not be decoded (\(error.localizedDescription, privacy: .public)); backed up to \(backup.lastPathComponent, privacy: .public)")
            return nil
        }
    }

    func save(_ projects: [Project]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(projects) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
