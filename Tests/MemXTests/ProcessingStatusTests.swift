import XCTest
@testable import MemXCore

final class ProcessingStatusTests: XCTestCase {

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
