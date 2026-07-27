import Foundation
#if canImport(FoundationModels)
import FoundationModels

// Schema-constrained outputs: the model can only fill these fields, which
// structurally eliminates "Sure," and "Here's..." preambles.
@available(macOS 26.0, *)
@Generable
struct CleanedDictation {
    @Guide(description: "The cleaned transcript text and nothing else")
    var text: String
}

@available(macOS 26.0, *)
@Generable
struct EditedText {
    @Guide(description: "The edited text and nothing else")
    var text: String
}
#endif

// Cleanup and edit passes backed by Apple's on-device Foundation Models
// (macOS 26 Apple Intelligence). Zero downloads, zero services, managed by
// the OS. Same downstream guardrails as the Ollama engine.
enum AppleCleaner {

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "available"
            case .unavailable(let reason):
                return "unavailable: \(String(describing: reason))"
            @unknown default:
                return "unavailable"
            }
        }
        #endif
        return "requires macOS 26"
    }

    static func cleanup(transcript: String, appName: String?, dictionary: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            var instructions = OllamaClient.systemPrompt(appName: appName, dictionary: dictionary)
            instructions += "\n\nExample transcript: \(OllamaClient.exampleInput)"
            instructions += "\nExample cleaned output: \(OllamaClient.exampleOutput)"
            instructions += "\n\nExample transcript: \(OllamaClient.exampleInputImperative)"
            instructions += "\nExample cleaned output: \(OllamaClient.exampleOutputImperative)"
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: transcript,
                generating: CleanedDictation.self,
                options: GenerationOptions(temperature: 0.1)
            )
            return response.content.text
        }
        #endif
        throw NSError(domain: "Riffle", code: 40,
                      userInfo: [NSLocalizedDescriptionKey: "Apple on-device model unavailable"])
    }

    static func edit(text: String, instruction: String, dictionary: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = OllamaClient.editSystemPrompt(dictionary: dictionary)
            let prompt = "TEXT TO EDIT:\n\(text)\n\nSPOKEN INSTRUCTION:\n\(instruction)"
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: prompt,
                generating: EditedText.self,
                options: GenerationOptions(temperature: 0.2)
            )
            return response.content.text
        }
        #endif
        throw NSError(domain: "Riffle", code: 41,
                      userInfo: [NSLocalizedDescriptionKey: "Apple on-device model unavailable"])
    }
}
