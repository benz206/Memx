import Foundation
import CoreGraphics

// Pure timing/geometry planning for the render pipeline. Kept free of
// AVFoundation so the beat-critical math is unit-testable.
//
// Model: each sequence item becomes a segment placed at its *plan* startTime
// (song-timeline seconds), so every cut stays locked to the beatgrid and the
// audio track. At each boundary the incoming clip starts exactly on the beat
// and fades/slides in over `headOverlap` while the outgoing clip keeps
// playing a tail (`presenceEnd - visibleEnd`) underneath it.

// MARK: - RenderSegmentPlan

struct RenderSegmentPlan {
    let index: Int
    let start: Double
    let visibleEnd: Double          // where the next clip takes over (== next start)
    let presenceEnd: Double         // visibleEnd + outgoing tail for the next boundary
    let headTransition: TransitionType
    let headOverlap: Double         // seconds this segment fades/slides in over
    let tailTransition: TransitionType?  // resolved transition at the NEXT boundary
    let tailOverlap: Double

    var sourceDuration: Double { presenceEnd - start }
    var visibleDuration: Double { visibleEnd - start }
}

// MARK: - SegmentMotion
// Ken Burns drift + beat punch-in, evaluated as scale-about-center over the
// segment's lifetime. Piecewise-linear enough that sampling at knot times and
// letting AVFoundation lerp between them is visually exact.

struct SegmentMotion {
    let startScale: Double
    let endScale: Double
    let panDX: Double               // -1...1 direction, amplitude derives from zoom
    let panDY: Double
    let punchScale: Double          // extra multiplier at t=0, decays to 1
    let punchDuration: Double

    func scale(atRelative t: Double, duration: Double) -> Double {
        let f = duration > 0 ? min(1, max(0, t / duration)) : 0
        var s = startScale + (endScale - startScale) * f
        if punchDuration > 0, t < punchDuration, punchScale > 1 {
            let pf = 1 - max(0, t) / punchDuration
            s *= 1 + (punchScale - 1) * pf
        }
        return s
    }
}

// MARK: - RenderTimeline

enum RenderTimeline {

    /// A flash-white or whip-pan *exit* planned by the sequencer outranks the
    /// incoming clip's transition — impact exits are beat hits.
    static func resolvedTransition(prevOut: TransitionType?, nextIn: TransitionType) -> TransitionType {
        guard let prevOut else { return nextIn }
        if prevOut == .flashWhite { return .flashWhite }
        if prevOut == .whipPan { return .whipPan }
        return nextIn
    }

    /// Overlap window at a boundary, clamped so short beat-burst clips never
    /// spend more than ~half their screen time inside a transition.
    static func overlapDuration(for transition: TransitionType,
                                prevVisible: Double, currVisible: Double) -> Double {
        let base: Double
        switch transition {
        case .hardCut, .fadeFromBlack: return 0
        case .flashWhite:    base = 0.15
        case .whipPan:       base = 0.25
        case .crossfade:     base = 0.5
        case .dissolve:      base = 0.9   // longer + slower curve than crossfade
        case .kenBurnsDrift: base = 0.8
        }
        return max(0, min(base, prevVisible * 0.45, currVisible * 0.45))
    }

    // MARK: - Easing
    // AVFoundation lerps linearly between ramp endpoints, so eased curves are
    // sampled at `easedKnotFractions` inside each transition window and the
    // compositor connects the chords.

    static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)          // smoothstep
    }

    static func easeInQuad(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t
    }

    static func easeOutCubic(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 1 - pow(1 - t, 3)
    }

    /// Interior sample points inside an eased window; two knots keep the
    /// piecewise-linear chord within ~2% of the smooth curve.
    static let easedKnotFractions: [Double] = [1.0 / 3.0, 2.0 / 3.0]

    static func fadeFromBlackDuration(_ plan: RenderSegmentPlan) -> Double {
        min(0.8, plan.visibleDuration * 0.5)
    }

    /// Whip-pan slide progress — fast out, settling in.
    static func whipProgress(_ fraction: Double) -> Double {
        easeOutCubic(fraction)
    }

    /// Opacity of a segment at absolute time `t`: its eased head transition
    /// combined with a flash-white tail exit.
    ///
    /// With stacked A/B tracks a frame composes as
    /// `a·In + (1−a)·b·Out + (1−a)(1−b)·bg`, so the only exact cross-dissolve
    /// is the outgoing clip held at 1.0 while the incoming eases up — fading
    /// both would dip toward the background mid-transition. Flash-white
    /// exploits that dip deliberately: the incoming blooms in late while the
    /// outgoing drops fast, letting the white background flash through.
    static func transitionOpacity(for plan: RenderSegmentPlan, at t: Double) -> Double {
        var o = 1.0
        switch plan.headTransition {
        case .crossfade, .kenBurnsDrift:
            if plan.headOverlap > 0, t < plan.start + plan.headOverlap {
                o = min(o, easeInOut((t - plan.start) / plan.headOverlap))
            }
        case .dissolve, .flashWhite:
            if plan.headOverlap > 0, t < plan.start + plan.headOverlap {
                o = min(o, easeInQuad((t - plan.start) / plan.headOverlap))
            }
        case .fadeFromBlack:
            let d = fadeFromBlackDuration(plan)
            if d > 0, t < plan.start + d {
                o = min(o, easeInOut((t - plan.start) / d))
            }
        case .hardCut, .whipPan:
            break
        }
        if plan.tailTransition == .flashWhite, plan.tailOverlap > 0, t > plan.visibleEnd {
            o = min(o, 1 - easeOutCubic((t - plan.visibleEnd) / plan.tailOverlap))
        }
        return max(0, min(1, o))
    }

    static func plan(_ sequence: [MontageSequenceItem]) -> [RenderSegmentPlan] {
        guard !sequence.isEmpty else { return [] }

        // Starts must be strictly increasing for the two-track overlap model.
        var starts = [Double]()
        starts.reserveCapacity(sequence.count)
        var cursor = -Double.greatestFiniteMagnitude
        for item in sequence {
            let s = max(item.startTime, cursor + 0.05)
            starts.append(s)
            cursor = s
        }

        // Visible end = next start (covers micro-gaps left by skipped slots);
        // the last clip ends at its planned end.
        var visibleEnds = [Double]()
        for i in sequence.indices {
            if i < sequence.count - 1 {
                visibleEnds.append(max(starts[i + 1], starts[i] + 0.05))
            } else {
                visibleEnds.append(max(sequence[i].endTime, starts[i] + 0.05))
            }
        }

        // Resolve every boundary (i = incoming segment index, i >= 1).
        var headTransitions = [TransitionType](repeating: .hardCut, count: sequence.count)
        var headOverlaps = [Double](repeating: 0, count: sequence.count)
        headTransitions[0] = sequence[0].transitionIn
        for i in 1..<sequence.count {
            let t = resolvedTransition(prevOut: sequence[i - 1].transitionOut,
                                       nextIn: sequence[i].transitionIn)
            headTransitions[i] = t
            headOverlaps[i] = overlapDuration(
                for: t,
                prevVisible: visibleEnds[i - 1] - starts[i - 1],
                currVisible: visibleEnds[i] - starts[i]
            )
        }

        return sequence.indices.map { i in
            let tailTransition: TransitionType? = i < sequence.count - 1 ? headTransitions[i + 1] : nil
            let tailOverlap = i < sequence.count - 1 ? headOverlaps[i + 1] : 0
            return RenderSegmentPlan(
                index: i,
                start: starts[i],
                visibleEnd: visibleEnds[i],
                presenceEnd: visibleEnds[i] + tailOverlap,
                headTransition: headTransitions[i],
                headOverlap: headOverlaps[i],
                tailTransition: tailTransition,
                tailOverlap: tailOverlap
            )
        }
    }

    // MARK: - Motion

    /// Ken Burns drift for photos, beat punch-ins for hits. Videos carry their
    /// own motion, so they only get the punch. Deterministic per position.
    static func motion(for item: MontageSequenceItem, isPhoto: Bool,
                       headTransition: TransitionType) -> SegmentMotion? {
        let isImpact = headTransition == .flashWhite
            || item.isHookMoment
            || item.sectionType == .drop

        guard isPhoto else {
            return isImpact
                ? SegmentMotion(startScale: 1, endScale: 1, panDX: 0, panDY: 0,
                                punchScale: 1.06, punchDuration: 0.30)
                : nil
        }

        if item.isAnticipationHold {
            return SegmentMotion(startScale: 1.0, endScale: 1.055, panDX: 0, panDY: 0,
                                 punchScale: 1, punchDuration: 0)
        }

        let drift = 0.045 + 0.05 * Double(min(1, max(0, item.motionIntensity)))
        let zoomIn = item.position % 2 == 0
        let panDirs: [(Double, Double)] = [(1, 0.35), (-1, -0.35), (-0.6, 1), (0.6, -1)]
        let pan = panDirs[abs(item.position) % panDirs.count]

        return SegmentMotion(
            startScale: zoomIn ? 1.0 : 1.0 + drift,
            endScale: zoomIn ? 1.0 + drift : 1.0,
            panDX: pan.0,
            panDY: pan.1,
            punchScale: isImpact ? 1.08 : 1,
            punchDuration: isImpact ? 0.30 : 0
        )
    }

    /// Push direction at a boundary — alternates so consecutive whips reverse.
    static func whipDirection(boundaryIndex: Int) -> Double {
        boundaryIndex % 2 == 0 ? -1.0 : 1.0
    }
}
