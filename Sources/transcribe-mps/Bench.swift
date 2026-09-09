import Foundation

enum Bench {
    /// Fixed chunk lengths to probe, in seconds. The Core ML encoder consumes
    /// a fixed 30s mel window regardless of input length, so short chunks may
    /// cost nearly as much as long ones - this is exactly what we're checking.
    static let chunkLengthsSeconds: [Double] = [2, 6, 12, 30]

    static func run(path: String, model: String, language: String?, repeats: Int) async throws {
        print("loading '\(path)'...")
        let samples = try AudioFile.loadMono16k(path: path)
        let totalSeconds = Double(samples.count) / Config.sampleRate
        print("  \(samples.count) samples @ \(Int(Config.sampleRate))Hz = \(String(format: "%.1f", totalSeconds))s")

        print("loading model '\(model)'...")
        let engine = TranscriptionEngine()
        let result = try await engine.load(model: model, language: language)
        print("  loaded in \(String(format: "%.1f", result.loadSeconds))s from \(result.modelFolder)")
        print("  compute: \(result.computeSummary)")

        for chunkSeconds in chunkLengthsSeconds {
            try await benchOneChunkLength(
                engine: engine,
                samples: samples,
                chunkSeconds: chunkSeconds,
                repeats: repeats
            )
        }
    }

    private static func benchOneChunkLength(
        engine: TranscriptionEngine,
        samples: [Float],
        chunkSeconds: Double,
        repeats: Int
    ) async throws {
        let chunkLen = Int(chunkSeconds * Config.sampleRate)
        guard chunkLen > 0, samples.count >= chunkLen else {
            print("--- \(chunkSeconds)s chunks: audio too short, skipping ---")
            return
        }

        var chunks: [[Float]] = []
        var start = 0
        while start + chunkLen <= samples.count {
            chunks.append(Array(samples[start..<(start + chunkLen)]))
            start += chunkLen
        }
        guard !chunks.isEmpty else { return }

        print("--- \(Int(chunkSeconds))s chunks (\(chunks.count) chunks x \(repeats) repeats) ---")

        var latenciesMs: [Double] = []
        var lastText = ""
        for run in 0..<repeats {
            for chunk in chunks {
                let t0 = Date()
                let lines = try await engine.transcribe(chunk)
                let ms = Date().timeIntervalSince(t0) * 1000
                // Discard the first repeat's timings as warmup.
                if run > 0 {
                    latenciesMs.append(ms)
                }
                if run == repeats - 1 {
                    lastText += lines.map(\.text).joined(separator: " ")
                }
            }
        }

        guard !latenciesMs.isEmpty else {
            print("  (only 1 repeat requested - no warm timings collected)")
            return
        }

        let sorted = latenciesMs.sorted()
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        let totalAudioSeconds = Double(chunks.count) * chunkSeconds
        let totalDecodeSeconds = latenciesMs.reduce(0, +) / 1000 / Double(repeats - 1)
        let rtf = totalAudioSeconds / max(totalDecodeSeconds, 0.001)

        print(String(format: "  p50 %.0fms  p95 %.0fms  RTF %.2fx", p50, p95, rtf))
        print("  sample text: \(String(lastText.prefix(160)))")
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int(Double(sorted.count - 1) * p)
        return sorted[idx]
    }
}
