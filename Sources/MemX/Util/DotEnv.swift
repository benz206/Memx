import Foundation
import OSLog

private let dotEnvLogger = Logger(subsystem: "com.memx.app", category: "dotenv")

/// Loads a `.env` file at startup so service configuration (API keys, model
/// overrides) can live alongside the project source. Swift / macOS apps don't
/// read `.env` automatically — `ProcessInfo.processInfo.environment` only
/// reflects vars exported by the launching shell. This loader searches a few
/// reasonable locations and caches the result.
enum DotEnv {

    static func value(forKey key: String) -> String? { cache[key] }

    private static let cache: [String: String] = loadAll()

    private static func loadAll() -> [String: String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var candidates: [URL] = []

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { candidates.append(url) }
        }

        // Walk up from this source file's compile-time path. This is the
        // ONLY reliable anchor when running under Xcode — the executable
        // lives in DerivedData and the CWD is typically set to that build
        // dir too, so neither reaches the project root.
        // `#filePath` is .../Memx/Sources/MemX/Util/DotEnv.swift at compile
        // time, so walking up finds the repo root quickly.
        do {
            let sourceFile = URL(fileURLWithPath: #filePath)
            var dir = sourceFile.deletingLastPathComponent()
            for _ in 0..<10 {
                add(dir.appendingPathComponent(".env"))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // CWD — works under `swift run`, `swift test`, and direct CLI launch.
        add(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env"))

        // Walk up from the executable — useful for hand-built binaries.
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                add(dir.appendingPathComponent(".env"))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // Last resort: a personal key in the user's home.
        add(fm.homeDirectoryForCurrentUser.appendingPathComponent(".env"))

        for url in candidates {
            guard fm.fileExists(atPath: url.path),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            dotEnvLogger.info("Loaded .env from \(url.path, privacy: .public)")
            return parse(contents)
        }
        dotEnvLogger.info(".env not found in any candidate location")
        return [:]
    }

    private static func parse(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in s.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.first == "\"" && val.last == "\"") || (val.first == "'" && val.last == "'") {
                val = String(val.dropFirst().dropLast())
            }
            // Strip optional `export ` prefix some users add.
            let normKey = key.hasPrefix("export ") ? String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) : key
            if !normKey.isEmpty && !val.isEmpty {
                result[normKey] = val
            }
        }
        return result
    }
}
