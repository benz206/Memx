import Foundation

// MARK: - MotionPrompt

struct MotionPrompt: Identifiable, Codable, Hashable {
    let id: UUID
    var assetID: String
    var prompt: String
    var isEdited: Bool
    var motionIntensity: Float      // 0.0 – 1.0, derived from song energy at clip position
    var status: MotionPromptStatus

    init(
        id: UUID = UUID(),
        assetID: String,
        prompt: String = "",
        isEdited: Bool = false,
        motionIntensity: Float = 0.5,
        status: MotionPromptStatus = .pending
    ) {
        self.id = id
        self.assetID = assetID
        self.prompt = prompt
        self.isEdited = isEdited
        self.motionIntensity = motionIntensity
        self.status = status
    }
}

// MARK: - MotionPromptStatus

enum MotionPromptStatus: String, Codable, Hashable {
    case pending    = "Pending"
    case generating = "Generating"
    case ready      = "Ready"
    case edited     = "Edited"

    var icon: String {
        switch self {
        case .pending:    return "hourglass"
        case .generating: return "sparkles"
        case .ready:      return "checkmark.circle.fill"
        case .edited:     return "pencil.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .pending:    return "secondary"
        case .generating: return "orange"
        case .ready:      return "green"
        case .edited:     return "blue"
        }
    }
}
