import CoreML
import Foundation
import WhisperKit

struct Line: Sendable {
    let offset: Double
    let text: String
}

/// Whisper models (trained on huge amounts of YouTube audio) are well known
/// to confidently hallucinate these exact short filler phrases when fed
/// silence, room tone, or breath noise - with LOW noSpeechProb, so the
/// no-speech gate alone does not catch them. This is the standard mitigation
/// used by most Whisper-based apps in lieu of a real neural VAD (which
/// WhisperKit does not ship - faster-whisper's `vad_filter=True`/Silero VAD
/// is what suppressed these in the Python tool).
private let hallucinationBlocklist: Set<String> = [
    "thank you", "thank you.", "thank you!",
    "thanks for watching", "thanks for watching.", "thanks for watching!",
    "thank you for watching", "thank you for watching.",
    "thank you very much", "thank you very much.",
    "please subscribe", "please subscribe to my channel",
    "you", "you.", "bye", "bye.", "bye-bye", "bye-bye.",
    "foreign", "foreign.",
]

private func isLikelyHallucination(_ text: String) -> Bool {
    let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return hallucinationBlocklist.contains(normalized)
}

enum EngineError: Error, CustomStringConvertible {
    case notLoaded
    case modelResolutionFailed(String)

    var description: String {
        switch self {
        case .notLoaded: return "WhisperKit model is not loaded"
        case .modelResolutionFailed(let m): return "failed to resolve/load model '\(m)'"
        }
    }
}

/// Owns the single (non-Sendable) WhisperKit instance and serializes all
/// calls into it via actor isolation. Never let a WhisperKit/TranscriptionResult
/// value escape this actor - only Sendable DTOs (Line) cross the boundary.
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var options = DecodingOptions()

    /// Downloads (if needed), loads, and prewarms the model. Returns
    /// (loadSeconds, modelFolder, computeSummary) for reporting - computeSummary
    /// makes it visible which compute unit (ANE/GPU/CPU) each stage actually runs on,
    /// since WhisperKit gives no runtime confirmation otherwise.
    @discardableResult
    func load(
        model: String = Config.defaultModel,
        language: String? = Config.defaultLanguage,
        initialPrompt: String? = nil,
        verbose: Bool = false
    ) async throws -> (loadSeconds: Double, modelFolder: String, computeSummary: String) {
        let loadStart = Date()
        // Explicit rather than relying on WhisperKitConfig's defaults, so we
        // can print exactly what's configured. audioEncoderCompute defaults
        // to .cpuAndNeuralEngine on macOS 14+ if left nil - made explicit here.
        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        let config = WhisperKitConfig(
            model: model,
            modelRepo: Config.modelRepo,
            computeOptions: computeOptions,
            verbose: verbose,
            logLevel: verbose ? .info : .error,
            prewarm: true,
            load: true,
            download: true
        )

        let kit: WhisperKit
        do {
            kit = try await WhisperKit(config)
        } catch {
            throw EngineError.modelResolutionFailed("\(model): \(error)")
        }

        var opts = DecodingOptions()
        opts.task = .transcribe
        opts.language = (language == "auto") ? nil : language
        opts.temperature = 0
        opts.temperatureFallbackCount = 1
        opts.skipSpecialTokens = true
        opts.chunkingStrategy = nil // our chunks are always < 30s

        if let prompt = initialPrompt, let tokenizer = kit.tokenizer {
            let trimmed = " " + prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            opts.promptTokens = tokenizer.encode(text: trimmed)
            opts.usePrefillPrompt = true
        }

        self.whisperKit = kit
        self.options = opts

        let modelFolder = kit.modelFolder?.path ?? "(unknown)"
        let computeSummary = "mel: \(Self.describe(computeOptions.melCompute)), "
            + "encoder: \(Self.describe(computeOptions.audioEncoderCompute)), "
            + "decoder: \(Self.describe(computeOptions.textDecoderCompute))"
        return (Date().timeIntervalSince(loadStart), modelFolder, computeSummary)
    }

    /// MLComputeUnits' default description is just "MLComputeUnits(rawValue: N)" -
    /// this gives a human-readable name so the ANE/GPU choice is actually visible.
    private static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "CPU only"
        case .cpuAndGPU: return "CPU+GPU"
        case .cpuAndNeuralEngine: return "CPU+ANE (Neural Engine)"
        case .all: return "CPU+GPU+ANE (auto)"
        @unknown default: return "\(units)"
        }
    }

    /// Transcribe one chunk of 16 kHz mono float samples. Not reentrant -
    /// callers must serialize (which a single consumer task guarantees).
    func transcribe(_ samples: [Float]) async throws -> [Line] {
        guard let kit = whisperKit else { throw EngineError.notLoaded }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).compactMap { segment -> Line? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Both signals must pass (not either/or) - matches how Whisper's
            // reference implementation treats no-speech and degenerate/
            // repetitive decoding as independent rejection criteria. The
            // compressionRatio check is what catches runaway repetition loops
            // (e.g. "Liberty, Liberty, Liberty..." or a repeated character).
            guard segment.noSpeechProb < 0.6 else { return nil }
            guard segment.compressionRatio < 2.4 else { return nil }
            guard !isLikelyHallucination(text) else { return nil }
            return Line(offset: max(0, Double(segment.start)), text: text)
        }
    }
}
