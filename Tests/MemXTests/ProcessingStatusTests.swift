import XCTest
@testable import MemXCore

final class ProcessingStatusTests: XCTestCase {

    private let projectID = UUID()

    // MARK: - ProcessingStatus computed properties

    func testIsCompleteReturnsFalseInitially() {
        let status = ProcessingStatus(projectID: projectID)
        XCTAssertFalse(status.isComplete)
    }

    func testIsCompleteTrueWhenPhaseIsComplete() {
        var status = ProcessingStatus(projectID: projectID)
        status.phase = .complete
        XCTAssertTrue(status.isComplete)
    }

    func testIsFailedReturnsFalseInitially() {
        let status = ProcessingStatus(projectID: projectID)
        XCTAssertFalse(status.isFailed)
    }

    func testIsFailedTrueWhenErrorIsSet() {
        var status = ProcessingStatus(projectID: projectID)
        status.error = "Something went wrong"
        XCTAssertTrue(status.isFailed)
    }

    func testInitialPhaseIsIdle() {
        let status = ProcessingStatus(projectID: projectID)
        XCTAssertEqual(status.phase, .idle)
    }

    func testInitialProgressIsZero() {
        let status = ProcessingStatus(projectID: projectID)
        XCTAssertEqual(status.progress, 0, accuracy: 0.001)
    }

    func testInitialMessageIsReady() {
        let status = ProcessingStatus(projectID: projectID)
        XCTAssertEqual(status.message, "Ready")
    }

    func testCompletedAtIsNilInitially() {
        let status = ProcessingStatus(projectID: projectID)
        XCTAssertNil(status.completedAt)
    }

    // MARK: - ProcessingPhase

    func testProcessingPhaseIndexOrdering() {
        let phases = ProcessingPhase.allCases
        for i in 0..<phases.count {
            XCTAssertEqual(phases[i].index, i, "\(phases[i]) has unexpected index")
        }
    }

    func testIdleIsFirst() {
        XCTAssertEqual(ProcessingPhase.idle.index, 0)
    }

    func testCompleteIsLast() {
        XCTAssertEqual(ProcessingPhase.complete.index, ProcessingPhase.allCases.count - 1)
    }

    func testAllPhasesHaveNonEmptyDescriptions() {
        for phase in ProcessingPhase.allCases {
            XCTAssertFalse(phase.description.isEmpty, "\(phase) description is empty")
        }
    }

    func testAllPhasesHaveNonEmptyIcons() {
        for phase in ProcessingPhase.allCases {
            XCTAssertFalse(phase.icon.isEmpty, "\(phase) icon is empty")
        }
    }

    func testCompletePhaseIconIsCheckmark() {
        XCTAssertEqual(ProcessingPhase.complete.icon, "checkmark.circle.fill")
    }

    func testAllPhasesRawValuesNonEmpty() {
        for phase in ProcessingPhase.allCases {
            XCTAssertFalse(phase.rawValue.isEmpty, "\(phase) rawValue is empty")
        }
    }

}
