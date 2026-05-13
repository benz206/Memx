import CoreGraphics
import Foundation
import OSLog

private let localVLMLogger = Logger(subsystem: "com.memx.app", category: "local-vlm")

protocol LocalVLMServiceProtocol {
    func describe(image: CGImage, instructions: String, prompt: String, maxTokens: Int) async -> String?
}

/// Compatibility shim for older call sites and tests.
///
/// MemX no longer loads an on-device VLM. Visual reasoning is routed through
/// OpenRouter so the Mac stays focused on media access and final stitching.
actor LocalVLMService: LocalVLMServiceProtocol {
    static let shared = LocalVLMService()

    private init() {}

    func describe(image: CGImage, instructions: String, prompt: String, maxTokens: Int) async -> String? {
        localVLMLogger.info("Local VLM disabled; forwarding caption request to OpenRouter")
        return await OpenRouterService.shared.caption(image: image, labels: [], prompt: prompt, maxTokens: maxTokens)
    }
}
