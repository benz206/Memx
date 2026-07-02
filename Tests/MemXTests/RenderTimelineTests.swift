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

    func testOverlapScalesWithBeatDuration() {
        // 1-beat crossfade, 2-beat dissolve at 150 BPM (0.4s beat).
        XCTAssertEqual(
            RenderTimeline.overlapDuration(for: .crossfade, prevVisible: 4, currVisible: 4, beatDuration: 0.4),
            0.4, accuracy: 1e-9)
        XCTAssertEqual(
            RenderTimeline.overlapDuration(for: .dissolve, prevVisible: 4, currVisible: 4, beatDuration: 0.4),
            0.8, accuracy: 1e-9)
    }

    func testOverlapCapsAtSlowTempo() {
        // 50 BPM: a 2-beat dissolve would be 2.4s — capped at 1.6s.
        XCTAssertEqual(
            RenderTimeline.overlapDuration(for: .dissolve, prevVisible: 8, currVisible: 8, beatDuration: 1.2),
            1.6, accuracy: 1e-9)
    }

    func testFlashWhiteStaysWallClockRegardlessOfTempo() {
        XCTAssertEqual(
            RenderTimeline.overlapDuration(for: .flashWhite, prevVisible: 4, currVisible: 4, beatDuration: 1.0),
            0.15, accuracy: 1e-9)
    }

    // MARK: - Easing & transition opacity

    private func plan(
        head: TransitionType,
        headOverlap: Double = 0,
        tail: TransitionType? = nil,
        tailOverlap: Double = 0,
        start: Double = 0,
        visibleEnd: Double = 4
    ) -> RenderSegmentPlan {
        RenderSegmentPlan(
            index: 1,
            start: start,
            visibleEnd: visibleEnd,
            presenceEnd: visibleEnd + tailOverlap,
            headTransition: head,
            headOverlap: headOverlap,
            tailTransition: tail,
            tailOverlap: tailOverlap
        )
    }

    func testEasingCurvesHitEndpointsAndStayMonotonic() {
        for ease in [RenderTimeline.easeInOut, RenderTimeline.easeInQuad, RenderTimeline.easeOutCubic] {
            XCTAssertEqual(ease(0), 0, accuracy: 1e-9)
            XCTAssertEqual(ease(1), 1, accuracy: 1e-9)
            XCTAssertEqual(ease(-0.5), 0, accuracy: 1e-9)
            XCTAssertEqual(ease(1.5), 1, accuracy: 1e-9)
            var prev = -1.0
            for step in 0...20 {
                let v = ease(Double(step) / 20)
                XCTAssertGreaterThanOrEqual(v, prev)
                prev = v
            }
        }
    }

    func testCrossfadeEntryIsEased() {
        let p = plan(head: .crossfade, headOverlap: 0.5)
        // Smoothstep sits below linear early in the window…
        XCTAssertLessThan(RenderTimeline.transitionOpacity(for: p, at: 0.125), 0.25)
        // …and reaches full opacity at the end of the overlap.
        XCTAssertEqual(RenderTimeline.transitionOpacity(for: p, at: 0.5), 1, accuracy: 1e-9)
    }

    func testOutgoingClipHoldsFullOpacityThroughCrossfadeTail() {
        // The only exact cross-dissolve on stacked tracks: outgoing stays at
        // 1.0 while the incoming eases up; fading both would dip to background.
        let p = plan(head: .hardCut, tail: .crossfade, tailOverlap: 0.5)
        XCTAssertEqual(RenderTimeline.transitionOpacity(for: p, at: 4.25), 1, accuracy: 1e-9)
    }

    func testDissolveStartsSlowerThanCrossfadeAndOverlapsLonger() {
        let cross = plan(head: .crossfade, headOverlap: 0.5)
        let diss = plan(head: .dissolve, headOverlap: 0.5)
        XCTAssertLessThan(
            RenderTimeline.transitionOpacity(for: diss, at: 0.125),
            RenderTimeline.transitionOpacity(for: cross, at: 0.125)
        )
        XCTAssertGreaterThan(
            RenderTimeline.overlapDuration(for: .dissolve, prevVisible: 4, currVisible: 4),
            RenderTimeline.overlapDuration(for: .crossfade, prevVisible: 4, currVisible: 4)
        )
    }

    func testFlashWhiteLeaksBackgroundAtMidOverlap() {
        // Incoming blooms late, outgoing drops fast: the white background
        // term (1-a)(1-b) must dominate at the middle of the flash window.
        let incoming = plan(head: .flashWhite, headOverlap: 0.15, start: 4, visibleEnd: 8)
        let outgoing = plan(head: .hardCut, tail: .flashWhite, tailOverlap: 0.15, start: 0, visibleEnd: 4)
        let mid = 4.075
        let a = RenderTimeline.transitionOpacity(for: incoming, at: mid)
        let b = RenderTimeline.transitionOpacity(for: outgoing, at: mid)
        XCTAssertGreaterThan((1 - a) * (1 - b), 0.4)
    }

    func testWhipProgressIsFastOutSlowIn() {
        XCTAssertEqual(RenderTimeline.whipProgress(0.5), 0.875, accuracy: 1e-9)
    }

    // MARK: - Beat pulses

    func testPulseGateFollowsSectionEnergyHierarchy() {
        XCTAssertEqual(RenderTimeline.pulseGate(section: .drop, energy: 0.5), 1.0)
        XCTAssertEqual(RenderTimeline.pulseGate(section: .chorus, energy: 0.5), 1.0)
        XCTAssertGreaterThan(
            RenderTimeline.pulseGate(section: .buildup, energy: 0.5),
            RenderTimeline.pulseGate(section: .verse, energy: 0.5)
        )
        XCTAssertEqual(RenderTimeline.pulseGate(section: .intro, energy: 0.9), 0)
        XCTAssertEqual(RenderTimeline.pulseGate(section: .outro, energy: 0.9), 0)
        // No section: energy-follower fallback, silent below the floor.
        XCTAssertEqual(RenderTimeline.pulseGate(section: nil, energy: 0.4), 0)
        XCTAssertGreaterThan(RenderTimeline.pulseGate(section: nil, energy: 0.9), 0.5)
    }

    func testBeatPulsesSkipQuietSectionsAndScaleWithStrength() {
        let beatmap = Beatmap(
            bpm: 120,
            durationSeconds: 4,
            energyCurve: [],
            sections: [
                BeatSection(type: .drop, start: 0, end: 2, energyAvg: 0.9),
                BeatSection(type: .intro, start: 2, end: 4, energyAvg: 0.2),
            ],
            beats: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5],
            drops: [],
            vocalPeaks: [],
            beatStrengths: [1, 0.5, 1, 0.5, 1, 0.5, 1, 0.5]
        )
        let pulses = RenderTimeline.beatPulses(beatmap: beatmap)
        XCTAssertFalse(pulses.isEmpty)
        XCTAssertTrue(pulses.allSatisfy { $0.time < 2 }, "Intro beats must not pulse")
        let strong = pulses.first { $0.time == 0 }
        let weak = pulses.first { $0.time == 0.5 }
        XCTAssertNotNil(strong)
        if let strong, let weak {
            XCTAssertGreaterThan(strong.depth, weak.depth)
        }
    }

    func testPulseEnvelopeSnapsOnBeatAndDecaysToFloor() {
        let pulse = RenderTimeline.BeatPulse(time: 1.0, depth: 0.08, decay: 0.3)
        let next = RenderTimeline.BeatPulse(time: 1.5, depth: 0.08, decay: 0.3)
        let env = RenderTimeline.PulseEnvelope(pulses: [pulse, next])

        XCTAssertEqual(env.value(atOrAfter: 1.0), 1.0, accuracy: 1e-9)          // snap
        XCTAssertEqual(env.value(atOrAfter: 1.35), 0.92, accuracy: 1e-9)        // floor after decay
        XCTAssertEqual(env.value(before: 1.5), 0.92, accuracy: 1e-9)            // dimmed just before next
        XCTAssertEqual(env.value(atOrAfter: 1.5), 1.0, accuracy: 1e-9)          // snaps again
        // Monotonically non-increasing between snap and floor.
        var prev = 1.0
        for step in 0...30 {
            let v = env.value(atOrAfter: 1.0 + Double(step) * 0.01)
            XCTAssertLessThanOrEqual(v, prev + 1e-9)
            prev = v
        }
    }

    func testPulseEnvelopeKnotsRespectMinSpacingAtExtremeBPM() {
        // 240 BPM: beats every 0.25s, knots would land 0.0875s apart untinned.
        let pulses = stride(from: 0.0, to: 10, by: 0.25).map {
            RenderTimeline.BeatPulse(time: $0, depth: 0.06, decay: 0.2)
        }
        let env = RenderTimeline.PulseEnvelope(pulses: pulses)
        let knots = env.knotTimes(in: 2, 4, minSpacing: 0.05)
        XCTAssertFalse(knots.isEmpty)
        for (a, b) in zip(knots, knots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.05 - 1e-9)
        }
        XCTAssertTrue(knots.allSatisfy { $0 > 2 && $0 < 4 })
    }

    func testEmptyPulseEnvelopeIsIdentity() {
        let env = RenderTimeline.PulseEnvelope(pulses: [])
        for t in [0.0, 1.7, 42.0] {
            XCTAssertEqual(env.value(atOrAfter: t), 1.0)
            XCTAssertEqual(env.value(before: t), 1.0)
        }
        XCTAssertTrue(env.knotTimes(in: 0, 60, minSpacing: 0.05).isEmpty)
    }

    func testPulseNeverBrightensBeyondTransitionEnvelope() {
        let pulse = RenderTimeline.BeatPulse(time: 0.1, depth: 0.08, decay: 0.3)
        let env = RenderTimeline.PulseEnvelope(pulses: [pulse])
        let p = plan(head: .crossfade, headOverlap: 0.5)
        for step in 0...50 {
            let t = Double(step) * 0.02
            let combined = RenderTimeline.transitionOpacity(for: p, at: t) * env.value(atOrAfter: t)
            XCTAssertLessThanOrEqual(combined, RenderTimeline.transitionOpacity(for: p, at: t) + 1e-9)
        }
    }

    func testSectionTintIsDarkAndChangesAcrossSections() {
        let sections: [SectionType] = [.intro, .verse, .preChorus, .chorus, .buildup, .drop, .bridge, .breakdown, .outro]
        for type in sections {
            let tint = RenderTimeline.sectionTint(type, hint: nil)
            XCTAssertLessThan(max(tint.r, max(tint.g, tint.b)), 0.15, "Tints must stay near-black")
        }
        let drop = RenderTimeline.sectionTint(.drop, hint: nil)
        let verse = RenderTimeline.sectionTint(.verse, hint: nil)
        XCTAssertNotEqual(drop.r, verse.r)
        // Same section + hint always yields the same tint (hue is section-stable).
        let a = RenderTimeline.sectionTint(.chorus, hint: .warm)
        let b = RenderTimeline.sectionTint(.chorus, hint: .warm)
        XCTAssertEqual(a.r, b.r)
        XCTAssertEqual(a.g, b.g)
        XCTAssertEqual(a.b, b.b)
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

    func testPlanLeadsTheBeatWhenGridIsKnown() {
        // With a beat grid, every cut after the first lands cutLead early so
        // the new image is onscreen when the transient hits. Audio placement
        // is unaffected; visible ends follow the shifted starts.
        let seq = [
            item(position: 0, start: 0.0, end: 2.0, transitionIn: .fadeFromBlack),
            item(position: 1, start: 2.0, end: 4.0, transitionIn: .hardCut),
            item(position: 2, start: 4.0, end: 6.0, transitionIn: .hardCut),
        ]
        let plans = RenderTimeline.plan(seq, beatDuration: 0.5)
        XCTAssertEqual(plans[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(plans[1].start, 2.0 - RenderTimeline.cutLead, accuracy: 1e-9)
        XCTAssertEqual(plans[2].start, 4.0 - RenderTimeline.cutLead, accuracy: 1e-9)
        XCTAssertEqual(plans[0].visibleEnd, plans[1].start, accuracy: 1e-9)
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
        XCTAssertEqual(plans[0].sourceDuration, 2.0 + 0.9, accuracy: 1e-9)
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

    func testEveryThirdNonImpactPhotoHoldsStatic() {
        // position % 3 == 2 → no drift, unless the slot is an impact.
        let still = RenderTimeline.motion(
            for: item(position: 2, start: 0, end: 2), isPhoto: true, headTransition: .hardCut)
        XCTAssertNil(still)
        let impact = RenderTimeline.motion(
            for: item(position: 2, start: 0, end: 1, section: .drop),
            isPhoto: true, headTransition: .hardCut)
        XCTAssertNotNil(impact, "impact slots keep their punch even at static positions")
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
