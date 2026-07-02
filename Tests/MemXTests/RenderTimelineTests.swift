import XCTest
@testable import MemXCore

final class RenderTimelineTests: XCTestCase {

    private func item(
        position: Int,
        start: Double,
        end: Double,
        transitionIn: TransitionType = .hardCut,
        transitionOut: TransitionType = .hardCut,
        isHook: Bool = false,
        section: SectionType? = .verse,
        motionIntensity: Float = 0.5
    ) -> MontageSequenceItem {
        MontageSequenceItem(
            position: position,
            assetID: "asset-\(position)",
            startTime: start,
            endTime: end,
            transitionIn: transitionIn,
            transitionOut: transitionOut,
            motionIntensity: motionIntensity,
            sectionType: section,
            isHookMoment: isHook
        )
    }

    // MARK: - resolvedTransition

    func testFlashWhiteExitOutranksIncomingTransition() {
        XCTAssertEqual(
            RenderTimeline.resolvedTransition(prevOut: .flashWhite, nextIn: .crossfade),
            .flashWhite
        )
    }

    func testHardCutExitDefersToIncomingTransition() {
        XCTAssertEqual(
            RenderTimeline.resolvedTransition(prevOut: .hardCut, nextIn: .dissolve),
            .dissolve
        )
    }

    func testNoPreviousUsesIncoming() {
        XCTAssertEqual(
            RenderTimeline.resolvedTransition(prevOut: nil, nextIn: .fadeFromBlack),
            .fadeFromBlack
        )
    }

    // MARK: - overlapDuration

    func testHardCutHasNoOverlap() {
        XCTAssertEqual(
            RenderTimeline.overlapDuration(for: .hardCut, prevVisible: 4, currVisible: 4), 0)
    }

    func testCrossfadeUsesBaseDurationWhenClipsAreLong() {
        XCTAssertEqual(
            RenderTimeline.overlapDuration(for: .crossfade, prevVisible: 4, currVisible: 4),
            0.5, accuracy: 1e-9)
    }

    func testOverlapClampsForShortBeatBurstClips() {
        // 0.4 s flash clips: overlap must stay under ~half their screen time.
        let d = RenderTimeline.overlapDuration(for: .crossfade, prevVisible: 0.4, currVisible: 0.4)
        XCTAssertEqual(d, 0.4 * 0.45, accuracy: 1e-9)
    }

    // MARK: - plan: beat lock

    func testPlanPreservesPlannedStartTimes() {
        let seq = [
            item(position: 0, start: 0.0, end: 2.0, transitionIn: .fadeFromBlack),
            item(position: 1, start: 2.0, end: 4.0, transitionIn: .crossfade),
            item(position: 2, start: 4.0, end: 6.0, transitionIn: .hardCut),
        ]
        let plans = RenderTimeline.plan(seq)
        XCTAssertEqual(plans.map(\.start), [0.0, 2.0, 4.0])
    }

    func testPlanCoversGapsFromSkippedSlots() {
        // Item 0 ends at 1.8 but item 1 starts at 2.4 (a slot was skipped):
        // the earlier clip must hold to the next start so no black hole shows.
        let seq = [
            item(position: 0, start: 0.0, end: 1.8),
            item(position: 1, start: 2.4, end: 4.0),
        ]
        let plans = RenderTimeline.plan(seq)
        XCTAssertEqual(plans[0].visibleEnd, 2.4, accuracy: 1e-9)
    }

    func testPresenceExtendsByNextBoundaryOverlap() {
        let seq = [
            item(position: 0, start: 0.0, end: 4.0, transitionOut: .hardCut),
            item(position: 1, start: 4.0, end: 8.0, transitionIn: .crossfade),
        ]
        let plans = RenderTimeline.plan(seq)
        // Outgoing clip holds a 0.5 s tail under the incoming crossfade.
        XCTAssertEqual(plans[0].presenceEnd, 4.5, accuracy: 1e-9)
        XCTAssertEqual(plans[0].tailTransition, .crossfade)
        XCTAssertEqual(plans[1].headOverlap, 0.5, accuracy: 1e-9)
        // Last clip has no tail.
        XCTAssertEqual(plans[1].presenceEnd, 8.0, accuracy: 1e-9)
    }

    func testFlashWhiteExitPropagatesToBoundary() {
        let seq = [
            item(position: 0, start: 0.0, end: 4.0, transitionOut: .flashWhite),
            item(position: 1, start: 4.0, end: 8.0, transitionIn: .hardCut),
        ]
        let plans = RenderTimeline.plan(seq)
        XCTAssertEqual(plans[1].headTransition, .flashWhite)
        XCTAssertEqual(plans[1].headOverlap, 0.15, accuracy: 1e-9)
    }

    func testSourceDurationCoversVisiblePlusTail() {
        let seq = [
            item(position: 0, start: 0.0, end: 2.0),
            item(position: 1, start: 2.0, end: 4.0, transitionIn: .dissolve),
        ]
        let plans = RenderTimeline.plan(seq)
        XCTAssertEqual(plans[0].sourceDuration, 2.0 + 0.6, accuracy: 1e-9)
    }

    func testNonMonotonicStartsAreRepaired() {
        let seq = [
            item(position: 0, start: 1.0, end: 2.0),
            item(position: 1, start: 0.5, end: 3.0),   // bad data: starts before prev
        ]
        let plans = RenderTimeline.plan(seq)
        XCTAssertGreaterThan(plans[1].start, plans[0].start)
        XCTAssertGreaterThan(plans[0].visibleEnd, plans[0].start)
    }

    // MARK: - Motion

    func testPhotoGetsKenBurnsDrift() {
        let m = RenderTimeline.motion(
            for: item(position: 0, start: 0, end: 2), isPhoto: true, headTransition: .hardCut)
        XCTAssertNotNil(m)
        XCTAssertNotEqual(m!.startScale, m!.endScale, "photos should always drift")
        XCTAssertGreaterThanOrEqual(min(m!.startScale, m!.endScale), 1.0, "never zoom below fit")
    }

    func testPlainVideoGetsNoMotion() {
        let m = RenderTimeline.motion(
            for: item(position: 0, start: 0, end: 2), isPhoto: false, headTransition: .crossfade)
        XCTAssertNil(m)
    }

    func testDropSlotGetsPunchIn() {
        let m = RenderTimeline.motion(
            for: item(position: 3, start: 0, end: 1, section: .drop),
            isPhoto: true, headTransition: .hardCut)
        XCTAssertNotNil(m)
        XCTAssertGreaterThan(m!.punchScale, 1.0)
        // Punch decays: scale right at the hit exceeds scale after the decay.
        let sAtHit = m!.scale(atRelative: 0, duration: 1)
        let sAfter = m!.scale(atRelative: m!.punchDuration, duration: 1)
        XCTAssertGreaterThan(sAtHit, sAfter)
    }

    func testAnticipationHoldGetsSlowPushIn() {
        var it = item(position: 5, start: 0, end: 2)
        it.isAnticipationHold = true
        let m = RenderTimeline.motion(for: it, isPhoto: true, headTransition: .dissolve)
        XCTAssertNotNil(m)
        XCTAssertGreaterThan(m!.endScale, m!.startScale)
        XCTAssertEqual(m!.punchScale, 1.0)
    }

    func testWhipDirectionAlternates() {
        XCTAssertNotEqual(
            RenderTimeline.whipDirection(boundaryIndex: 2),
            RenderTimeline.whipDirection(boundaryIndex: 3))
    }
}
