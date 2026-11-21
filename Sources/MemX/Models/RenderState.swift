import Foundation

// MARK: - RenderState

enum RenderState: Hashable {
    case idle
    case rendering(progress: Double, message: String)
    case finished(URL)
    case failed(String)
    case cancelled

    func next(on event: RenderEvent) -> RenderState? {
        switch (self, event) {
        case let (state, .start(message)):
            return state.isRendering ? nil : .rendering(progress: 0, message: message)
        case let (.rendering, .progress(progress, message)):
            return .rendering(progress: progress, message: message)
        case let (.rendering, .finish(url)):
            return .finished(url)
        case let (.rendering, .fail(message)):
            return .failed(message)
        case (.rendering, .cancel):
            return .cancelled
        case let (state, .reset):
            return state.isRendering ? nil : .idle
        default:
            return nil
        }
    }

    var isRendering: Bool {
        if case .rendering = self { return true }
        return false
    }

    var progress: Double {
        if case let .rendering(progress, _) = self { return progress }
        return 0
    }

    var message: String {
        if case let .rendering(_, message) = self { return message }
        return ""
    }

    var videoURL: URL? {
        if case let .finished(url) = self { return url }
        return nil
    }

    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

enum RenderEvent: Hashable {
    case start(String)
    case progress(Double, String)
    case finish(URL)
    case fail(String)
    case cancel
    case reset
}
