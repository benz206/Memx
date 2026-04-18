import CoreGraphics
import CoreImage
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import OSLog
import Tokenizers

private let logger = Logger(subsystem: "com.memx.app", category: "local-vlm")

protocol LocalVLMServiceProtocol {
    func describe(image: CGImage, instructions: String, prompt: String, maxTokens: Int) async -> String?
}

actor LocalVLMService: LocalVLMServiceProtocol {

    static let shared = LocalVLMService()
    private init() {}

    private static let modelConfiguration = VLMRegistry.qwen2VL2BInstruct4Bit
    private static let timeoutSeconds: TimeInterval = 20

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var unavailable = false

    private func loadedContainer() async -> ModelContainer? {
        if unavailable { return nil }
        if let container { return container }

        if loadTask == nil {
            loadTask = Task {
                logger.info("VLM model load starting: \(Self.modelConfiguration.name)")
                return try await VLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: Self.modelConfiguration
                )
            }
        }

        do {
            let c = try await loadTask!.value
            container = c
            logger.info("VLM model ready")
            return c
        } catch {
            logger.error("VLM model load failed: \(String(describing: error), privacy: .public)")
            unavailable = true
            loadTask = nil
            return nil
        }
    }

    func describe(image: CGImage, instructions: String, prompt: String, maxTokens: Int) async -> String? {
        guard let container = await loadedContainer() else { return nil }
        return await Self.runInference(
            container: container,
            image: image,
            instructions: instructions,
            prompt: prompt,
            maxTokens: maxTokens
        )
    }

    private static func runInference(
        container: ModelContainer,
        image: CGImage,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async -> String? {
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let start = Date()
                do {
                    let ciImage = CIImage(cgImage: image)
                    let chat: [Chat.Message] = [
                        .system(instructions),
                        .user(prompt, images: [.ciImage(ciImage)]),
                    ]
                    let userInput = UserInput(chat: chat)
                    let lmInput = try await container.prepare(input: userInput)
                    let stream = try await container.generate(
                        input: lmInput,
                        parameters: GenerateParameters(maxTokens: maxTokens)
                    )
                    var result = ""
                    for await generation in stream {
                        if let chunk = generation.chunk {
                            result += chunk
                        }
                    }
                    let elapsed = Date().timeIntervalSince(start)
                    let raw = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.info("VLM response in \(elapsed, format: .fixed(precision: 2))s — \(raw.count) chars")
                    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return trimmed.isEmpty ? nil : trimmed
                } catch {
                    let elapsed = Date().timeIntervalSince(start)
                    logger.warning(
                        "VLM error after \(elapsed, format: .fixed(precision: 2))s: \(String(describing: error), privacy: .public)"
                    )
                    return nil
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    logger.warning("VLM timeout after \(timeoutSeconds, format: .fixed(precision: 1))s")
                    return nil
                } catch {
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
