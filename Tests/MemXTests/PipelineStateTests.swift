import XCTest
@testable import MemXCore

final class PipelineStateTests: XCTestCase {

    private let scoring = PipelineState.running(phase: .scoringPhotos, progress: 0.4, message: "Scoring")

    // MARK: - start

    func testStartFromEveryRestingStateEntersRunning() {
        let resting: [PipelineState] = [
            .idle,
            .completed(at: Date()),
            .failed(phase: .scoringPhotos, progress: 0.3, message: "x"),
            .cancelled(phase: .analyzingAudio, progress: 0.1),
            .awaitingShortfallAck(progress: 0.85),
        ]
        for state in resting {
            XCTAssertEqual(state.next(on: .start(.analyzingAudio, progress: 0, message: "Go")),
                           .running(phase: .analyzingAudio, progress: 0, message: "Go"), "\(state)")
        }
    }

    func testStartWhileRunningIsRejected() {
        XCTAssertNil(scoring.next(on: .start(.analyzingAudio, progress: 0, message: "Go")))
    }

    func testStartRequiresAWorkPhase() {
        XCTAssertNil(PipelineState.idle.next(on: .start(.idle, progress: 0, message: "")))
        XCTAssertNil(PipelineState.idle.next(on: .start(.complete, progress: 0, message: "")))
    }

    // MARK: - progress

    func testProgressWithinPhaseUpdatesPayload() {
        XCTAssertEqual(scoring.next(on: .progress(.scoringPhotos, progress: 0.5, message: "More")),
                       .running(phase: .scoringPhotos, progress: 0.5, message: "More"))
    }

    func testProgressAdvancesForward() {
        XCTAssertEqual(scoring.next(on: .progress(.sequencing, progress: 0.85, message: "Build")),
                       .running(phase: .sequencing, progress: 0.85, message: "Build"))
    }

    func testLateProgressFromEarlierPhaseIsRejected() {
        XCTAssertNil(scoring.next(on: .progress(.analyzingAudio, progress: 0.1, message: "late")))
    }

    func testProgressWhenNotRunningIsRejected() {
        XCTAssertNil(PipelineState.idle.next(on: .progress(.scoringPhotos, progress: 0.3, message: "")))
        XCTAssertNil(PipelineState.completed(at: Date()).next(on: .progress(.sequencing, progress: 0.9, message: "")))
    }

    // MARK: - terminal transitions

    func testCompleteOnlyFromSequencing() {
        let date = Date()
        XCTAssertNil(scoring.next(on: .complete(at: date)))
        let sequencing = PipelineState.running(phase: .sequencing, progress: 0.9, message: "")
        XCTAssertEqual(sequencing.next(on: .complete(at: date)), .completed(at: date))
    }

    func testFailCapturesPhaseAndProgress() {
        XCTAssertEqual(scoring.next(on: .fail("boom")),
                       .failed(phase: .scoringPhotos, progress: 0.4, message: "boom"))
        XCTAssertNil(PipelineState.idle.next(on: .fail("boom")))
    }

    func testCancelCapturesPhaseAndProgress() {
        XCTAssertEqual(scoring.next(on: .cancel), .cancelled(phase: .scoringPhotos, progress: 0.4))
        XCTAssertNil(PipelineState.idle.next(on: .cancel))
    }

    func testFinishStepReturnsToIdle() {
        let audio = PipelineState.running(phase: .analyzingAudio, progress: 0.2, message: "")
        XCTAssertEqual(audio.next(on: .finishStep), .idle)
        XCTAssertNil(PipelineState.idle.next(on: .finishStep))
    }

    func testAwaitShortfallAckPausesRun() {
        XCTAssertEqual(scoring.next(on: .awaitShortfallAck), .awaitingShortfallAck(progress: 0.4))
        XCTAssertNil(PipelineState.idle.next(on: .awaitShortfallAck))
    }

    func testResetIsRejectedWhileRunning() {
        XCTAssertNil(scoring.next(on: .reset))
        XCTAssertEqual(PipelineState.failed(phase: .sequencing, progress: 0.9, message: "").next(on: .reset), .idle)
        XCTAssertEqual(PipelineState.awaitingShortfallAck(progress: 0.85).next(on: .reset), .idle)
    }

    // MARK: - derived accessors

    func testDerivedAccessors() {
        XCTAssertEqual(PipelineState.idle.phase, .idle)
        XCTAssertEqual(PipelineState.completed(at: Date()).phase, .complete)
        XCTAssertEqual(PipelineState.completed(at: Date()).progress, 1)
        XCTAssertEqual(PipelineState.awaitingShortfallAck(progress: 0.85).phase, .sequencing)
        XCTAssertTrue(scoring.isRunning)
        XCTAssertFalse(PipelineState.awaitingShortfallAck(progress: 0.85).isRunning)
        XCTAssertEqual(PipelineState.failed(phase: .scoringPhotos, progress: 0.3, message: "boom").errorMessage, "boom")
        XCTAssertNil(scoring.errorMessage)
    }

    func testWorkPhases() {
        XCTAssertEqual(ProcessingPhase.allCases.filter(\.isWorkPhase), [.analyzingAudio, .scoringPhotos, .sequencing])
    }
}

final class ShortfallGateTests: XCTestCase {

    private let short = SequencerPreflight(requiredClipCount: 20, availableClipCount: 12,
                                           estimatedShortfall: 8, estimatedShortfallSeconds: 16)
    private let enough = SequencerPreflight(requiredClipCount: 10, availableClipCount: 12,
                                            estimatedShortfall: 0, estimatedShortfallSeconds: 0)

    func testEvaluateWithShortfallWarns() {
        XCTAssertEqual(ShortfallGate.clear.next(on: .evaluate(short)), .warning(short))
        XCTAssertTrue(ShortfallGate.warning(short).blocksBuild)
    }

    func testEvaluateWithoutShortfallClears() {
        XCTAssertEqual(ShortfallGate.warning(short).next(on: .evaluate(enough)), .clear)
        XCTAssertEqual(ShortfallGate.acknowledged.next(on: .evaluate(enough)), .clear)
    }

    func testAcknowledgementSurvivesReevaluation() {
        XCTAssertEqual(ShortfallGate.acknowledged.next(on: .evaluate(short)), .acknowledged)
        XCTAssertFalse(ShortfallGate.acknowledged.blocksBuild)
    }

    func testAcknowledgeAndDismissOnlyFromWarning() {
        XCTAssertEqual(ShortfallGate.warning(short).next(on: .acknowledge), .acknowledged)
        XCTAssertEqual(ShortfallGate.warning(short).next(on: .dismiss), .clear)
        XCTAssertNil(ShortfallGate.clear.next(on: .acknowledge))
        XCTAssertNil(ShortfallGate.clear.next(on: .dismiss))
        XCTAssertNil(ShortfallGate.acknowledged.next(on: .acknowledge))
    }

    func testResetAlwaysClears() {
        XCTAssertEqual(ShortfallGate.acknowledged.next(on: .reset), .clear)
        XCTAssertEqual(ShortfallGate.warning(short).next(on: .reset), .clear)
    }
}
