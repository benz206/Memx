import XCTest
@testable import MemXCore

final class ProjectStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memx-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileLoadsAsEmpty() {
        let store = ProjectStore(fileURL: dir.appendingPathComponent("projects.json"))
        XCTAssertEqual(store.load()?.count, 0)
    }

    func testSavedProjectsRoundTrip() {
        let store = ProjectStore(fileURL: dir.appendingPathComponent("projects.json"))
        store.save([Project(title: "A"), Project(title: "B")])
        XCTAssertEqual(store.load()?.map(\.title), ["A", "B"])
    }

    func testUnreadableFileReturnsNilAndIsBackedUp() throws {
        let url = dir.appendingPathComponent("projects.json")
        try Data("{ not json".utf8).write(to: url)
        let store = ProjectStore(fileURL: url)

        XCTAssertNil(store.load())

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("projects.unreadable-") }
        XCTAssertEqual(backups.count, 1)
        let backupData = try Data(contentsOf: dir.appendingPathComponent(backups[0]))
        XCTAssertEqual(String(decoding: backupData, as: UTF8.self), "{ not json")
    }
}
