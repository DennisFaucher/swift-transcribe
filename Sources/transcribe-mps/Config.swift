import Foundation

enum Config {
    // Device matching (case-insensitive substring match)
    static let defaultMicSubstring = "RODE NT-USB"

    // Chunking: emit audio for transcription when a natural pause is detected,
    // or force-flush if a speaker talks continuously for too long. Ported
    // verbatim from the Python tool's config.py.
    static let minChunkSeconds = 2.0
    static let maxChunkSeconds = 12.0
    static let silenceTailSeconds = 0.7
    static let silenceRMSThreshold: Float = 0.004

    // Backpressure: max chunks queued between capture and transcription.
    // When the model cannot keep up, the OLDEST chunk is dropped (newest kept).
    static let queueMaxChunks = 30

    // Whisper
    static let defaultModel = "large-v3-v20240930_turbo"
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    static let defaultLanguage = "en"

    static let sampleRate: Double = 16_000

    static let maxConsecutiveErrors = 5
}
