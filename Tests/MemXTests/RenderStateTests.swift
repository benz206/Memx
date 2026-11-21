import XCTest
@testable import MemXCore

final class RenderStateTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/out.mp4")
    private let rendering = RenderState.rendering(progress: 0.4, message: "Encoding")

    func testStartFromEveryRestingState() {
        let resting: [RenderState] = [.idle, .finished(url), .failed("x"), .cancelled]
        for state in resting {
            XCTAssertEqual(state.next(on: .start("Go")), .rendering(progress: 0, message: "Go"), "\(state)")
        }
        XCTAssertNil(rendering.next(on: .start("Go")))
    }

    func testProgressOnlyWhileRendering() {
        XCTAssertEqual(rendering.next(on: .progress(0.6, "More")), .rendering(progress: 0.6, message: "More"))
        XCTAssertNil(RenderState.finished(url).next(on: .progress(0.9, "late")))
        XCTAssertNil(RenderState.idle.next(on: .progress(0.1, "")))
    }

    func testTerminalEventsOnlyWhileRendering() {
        XCTAssertEqual(rendering.next(on: .finish(url)), .finished(url))
        XCTAssertEqual(rendering.next(on: .fail("boom")), .failed("boom"))
        XCTAssertEqual(rendering.next(on: .cancel), .cancelled)
        XCTAssertNil(RenderState.idle.next(on: .finish(url)))
        XCTAssertNil(RenderState.idle.next(on: .fail("boom")))
        XCTAssertNil(RenderState.idle.next(on: .cancel))
    }

    func testResetIsRejectedWhileRendering() {
        XCTAssertNil(rendering.next(on: .reset))
        XCTAssertEqual(RenderState.finished(url).next(on: .reset), .idle)
        XCTAssertEqual(RenderState.failed("x").next(on: .reset), .idle)
    }

    func testDerivedAccessors() {
        XCTAssertTrue(rendering.isRendering)
        XCTAssertEqual(rendering.progress, 0.4)
        XCTAssertEqual(rendering.message, "Encoding")
        XCTAssertEqual(RenderState.finished(url).videoURL, url)
        XCTAssertNil(rendering.videoURL)
        XCTAssertEqual(RenderState.failed("boom").errorMessage, "boom")
        XCTAssertNil(RenderState.cancelled.errorMessage)
    }
}
