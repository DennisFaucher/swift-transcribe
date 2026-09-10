import Accelerate
import Foundation

struct SpeechChunk: Sendable {
    let source: String
    let startedAt: Double // wall-clock epoch seconds at voice onset
    let samples: [Float]  // 16 kHz mono
    let averageRMS: Float // RMS over the whole chunk, not just one 20ms frame
}

/// Silence-aware chunker at 16 kHz, ported from the Python tool's
/// `_Segmenter` (recorder.py). Buffers audio until a natural pause or a
/// max-length cutoff, then emits from the first voiced sample onward
/// (leading silence trimmed, trailing silence kept). Pure-silence buffers
/// are discarded, never emitted. Not thread-safe - each source owns one
/// instance and feeds it from a single queue.
final class Segmenter {
    private let source: String
    private let minSamples: Int
    private let maxSamples: Int
    private let tailSamples: Int
    private let frameSize = max(1, Int(0.02 * Config.sampleRate)) // 20ms analysis frames

    private var pending: [Float] = []
    private var voicedFromIndex: Int?
    private var silenceSamples = 0
    private var voiceStartedAt: Double?

    init(source: String) {
        self.source = source
        self.minSamples = max(1, Int(Config.minChunkSeconds * Config.sampleRate))
        self.maxSamples = max(minSamples + 1, Int(Config.maxChunkSeconds * Config.sampleRate))
        self.tailSamples = max(1, Int(Config.silenceTailSeconds * Config.sampleRate))
    }

    /// Feed newly captured samples (any length); returns any chunks flushed.
    func feed(_ block: [Float]) -> [SpeechChunk] {
        var out: [SpeechChunk] = []
        var offset = 0
        while offset < block.count {
            let end = min(offset + frameSize, block.count)
            if let chunk = feedFrame(Array(block[offset..<end])) {
                out.append(chunk)
            }
            offset = end
        }
        return out
    }

    /// Emit any buffered voiced audio - used on stop, to flush a trailing chunk.
    func flushRemaining() -> SpeechChunk? {
        flush()
    }

    private func feedFrame(_ frame: [Float]) -> SpeechChunk? {
        pending.append(contentsOf: frame)
        let n = frame.count
        let frameRMS = rms(frame)

        if frameRMS < Config.silenceRMSThreshold {
            if voicedFromIndex != nil {
                silenceSamples += n
            }
        } else {
            silenceSamples = 0
            if voicedFromIndex == nil {
                voicedFromIndex = pending.count - n
                voiceStartedAt = Date().timeIntervalSince1970
            }
        }

        if let from = voicedFromIndex {
            let voicedLength = pending.count - from
            if voicedLength >= minSamples && silenceSamples >= tailSamples {
                return flush()
            }
        }
        if pending.count >= maxSamples {
            return flush()
        }
        return nil
    }

    private func flush() -> SpeechChunk? {
        defer { reset() }
        guard let from = voicedFromIndex, from < pending.count, let startedAt = voiceStartedAt else { return nil }
        let voiced = Array(pending[from...])
        return SpeechChunk(source: source, startedAt: startedAt, samples: voiced, averageRMS: rms(voiced))
    }

    private func reset() {
        pending.removeAll(keepingCapacity: true)
        voicedFromIndex = nil
        silenceSamples = 0
        voiceStartedAt = nil
    }

    private func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(frame, 1, &result, vDSP_Length(frame.count))
        return result
    }
}
