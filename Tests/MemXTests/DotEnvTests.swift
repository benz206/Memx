import XCTest
@testable import MemXCore

final class DotEnvTests: XCTestCase {

    func testProjectDotEnvLoadsOpenRouterKey() {
        // The project's own .env should be discoverable via the CWD walk
        // when tests run with swift test from the package root. This guards
        // against regressions in path walking or parsing.
        let key = DotEnv.value(forKey: "OPENROUTER_API_KEY")
        XCTAssertNotNil(key, "Expected DotEnv to find OPENROUTER_API_KEY in the project's .env")
        if let key {
            XCTAssertFalse(key.isEmpty)
            XCTAssertGreaterThan(key.count, 20, "OpenRouter keys are long; got \(key.count) chars")
        }
    }
}
