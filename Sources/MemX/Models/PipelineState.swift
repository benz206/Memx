import Foundation

// MARK: - PipelineState

enum PipelineState: Hashable {
    case idle
    case running(phase: ProcessingPhase, progress: Double, message: String)
    case awaitingShortfallAck(progress: Double)
    case completed(at: Date)
    case failed(phase: ProcessingPhase, progress: Double, message: String)
    case cancelled(phase: ProcessingPhase, progress: Double)

    func next(on event: PipelineEvent) -> PipelineState? {
        switch (self, event) {
        case let (state, .start(phase, progress, message)):
            guard !state.isRunning, phase.isWorkPhase else { return nil }
            return .running(phase: phase, progress: progress, message: message)
        case let (.running(current, _, _), .progress(phase, progress, message)):
            guard phase.isWorkPhase, phase.index >= current.index else { return nil }
            return .running(phase: phase, progress: progress, message: message)
        case let (.running(_, progress, _), .awaitShortfallAck):
            return .awaitingShortfallAck(progress: progress)
        case (.running, .finishStep):
            return .idle
        case let (.running(.sequencing, _, _), .complete(date)):
            return .completed(at: date)
        case let (.running(phase, progress, _), .fail(message)):
            return .failed(phase: phase, progress: progress, message: message)
        case let (.running(phase, progress, _), .cancel):
            return .cancelled(phase: phase, progress: progress)
        case let (state, .reset):
            return state.isRunning ? nil : .idle
        default:
            return nil
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var phase: ProcessingPhase {
        switch self {
        case .idle:                                  return .idle
        case let .running(phase, _, _):              return phase
        case .awaitingShortfallAck:                  return .sequencing
        case .completed:                             return .complete
        case let .failed(phase, _, _):               return phase
        case let .cancelled(phase, _):               return phase
        }
    }

    var progress: Double {
        switch self {
        case .idle:                                  return 0
        case let .running(_, progress, _):           return progress
        case let .awaitingShortfallAck(progress):    return progress
        case .completed:                             return 1
        case let .failed(_, progress, _):            return progress
        case let .cancelled(_, progress):            return progress
        }
    }

    var message: String {
        switch self {
        case .idle:                                  return "Ready"
        case let .running(_, _, message):            return message
        case .awaitingShortfallAck:                  return "Waiting for confirmation — not enough clips to fill the song"
        case .completed:                             return ProcessingPhase.complete.description
        case let .failed(_, _, message):             return message
        case .cancelled:                             return "Pipeline cancelled"
        }
    }

    var errorMessage: String? {
        if case let .failed(_, _, message) = self { return message }
        return nil
    }
}

enum PipelineEvent: Hashable {
    case start(ProcessingPhase, progress: Double, message: String)
    case progress(ProcessingPhase, progress: Double, message: String)
    case awaitShortfallAck
    case finishStep
    case complete(at: Date)
    case fail(String)
    case cancel
    case reset
}

// MARK: - ShortfallGate

enum ShortfallGate: Hashable {
    case clear
    case warning(SequencerPreflight)
    case acknowledged

    func next(on event: ShortfallGateEvent) -> ShortfallGate? {
        switch (self, event) {
        case let (.acknowledged, .evaluate(preflight)) where preflight.hasShortfall:
            return .acknowledged
        case let (_, .evaluate(preflight)):
            return preflight.hasShortfall ? .warning(preflight) : .clear
        case (.warning, .acknowledge):
            return .acknowledged
        case (.warning, .dismiss):
            return .clear
        case (_, .reset):
            return .clear
        default:
            return nil
        }
    }

    var warning: SequencerPreflight? {
        if case let .warning(preflight) = self { return preflight }
        return nil
    }

    var blocksBuild: Bool { warning != nil }
}

enum ShortfallGateEvent: Hashable {
    case evaluate(SequencerPreflight)
    case acknowledge
    case dismiss
    case reset
}
