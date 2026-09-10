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

    // A single 20ms frame spiking above silenceRMSThreshold (self-noise burst,
    // USB hum, a click) is enough to flip the segmenter into "voiced" for a
    // whole chunk, even when the source (e.g. a muted mic) is otherwise
    // near-silent. Whisper reliably hallucinates plausible-sounding text for
    // such chunks rather than returning nothing, so chunks whose RMS averaged
    // over the *entire* chunk falls below this stricter threshold are dropped
    // before ever reaching the transcriber.
    static let chunkAverageRMSThreshold: Float = 0.006

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
