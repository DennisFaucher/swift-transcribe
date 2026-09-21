import CoreAudio
import Dispatch
import Foundation

/// Orchestrates capture -> segmentation -> transcription -> transcript file
/// for a live recording session. Not an actor: setup runs single-threaded in
/// `run()` before any capture starts, and the mutable state touched after
/// that (consecutiveErrors, fatalMessage, stopRequested) is each touched from
/// only one task/handler, which is an accepted simplification for a
/// single-owner CLI tool rather than a fully actor-isolated design.
final class Session {
    private let outdir: String
    private let modelName: String
    private let language: String?
    private let initialPrompt: String?
    private let micSubstring: String
    private let speakersSubstring: String?
    private let spellingFile: String?
    private var spellingCorrector: SpellingCorrector?

    private let engine = TranscriptionEngine()
    private let queue = ChunkQueue()
    private var writer: TranscriptWriter!

    private var captures: [CoreAudioCapture] = []
    private var segmenters: [String: Segmenter] = [:]
    private var systemTap: SystemAudioTap?
    private var sigintSource: DispatchSourceSignal?

    private var consecutiveErrors = 0
    private var fatalMessage: String?
    private var stopRequested = false

    /// Last few accepted lines per source, used to suppress consecutive
    /// independent chunks that hallucinate the same short filler (e.g. "The"
    /// repeated over silence/music, or "Thank you" repeated on room tone).
    /// This catches what the single-chunk compressionRatio/blocklist checks
    /// in TranscriptionEngine cannot, since each chunk's own text isn't
    /// internally repetitive - only the sequence across chunks is.
    private var recentTextsBySource: [String: [String]] = [:]

    init(outdir: String, model: String, language: String?, initialPrompt: String?, micSubstring: String, speakersSubstring: String? = nil, spellingFile: String? = nil) {
        self.outdir = outdir
        self.modelName = model
        self.language = language
        self.initialPrompt = initialPrompt
        self.micSubstring = micSubstring
        self.speakersSubstring = speakersSubstring
        self.spellingFile = spellingFile
    }

    func run() async {
        print("Starting meeting transcription")

        let spellingPath = spellingFile ?? Config.defaultSpellingFile
        if let corrector = SpellingCorrector.load(path: spellingPath) {
            spellingCorrector = corrector
            print("  spelling corrections: \(corrector.count) loaded from \(spellingPath)")
        } else if spellingFile != nil {
            print("  [note] could not load spelling corrections from '\(spellingPath)'")
        }

        guard let mic = try? CoreAudioDevices.findInput(nameContains: micSubstring) else {
            print("No input device matching '\(micSubstring)'. Available inputs:")
            for (i, d) in ((try? CoreAudioDevices.listInputs()) ?? []).enumerated() {
                print("  [\(i)] \(d.name)")
            }
            exit(1)
        }

        var sources: [(name: String, deviceID: AudioObjectID)] = [(mic.name, mic.id)]

        let tap = SystemAudioTap()
        do {
            let (tapDeviceID, tapDeviceName) = try tap.start(speakersSubstring: speakersSubstring)
            systemTap = tap
            // Distinguish from the mic source's own label, which can name the
            // same physical device (e.g. Bluetooth earbuds used for both).
            sources.append(("System Audio (\(tapDeviceName))", tapDeviceID))
        } catch {
            print("[note] system-audio tap unavailable (\(error)) - transcribing mic only")
        }

        let sessionDir = URL(fileURLWithPath: outdir)
            .appendingPathComponent(TranscriptWriter.sessionStamp(Date()))
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        do {
            writer = try TranscriptWriter(path: sessionDir.appendingPathComponent("transcript.md"), sources: sources.map(\.name))
        } catch {
            print("ERROR: cannot create transcript file: \(error)")
            exit(1)
        }

        for s in sources {
            print("  recording from: \(s.name)")
        }

        await writer.status("loading whisper model '\(modelName)' (first run downloads it)")
        do {
            let result = try await engine.load(model: modelName, language: language, initialPrompt: initialPrompt)
            await writer.status("compute: \(result.computeSummary)")
        } catch {
            print("\nERROR: failed to load whisper model '\(modelName)': \(error)")
            exit(1)
        }
        await writer.status("model ready - listening")
        print("\nTranscribing live. Press Ctrl+C to stop.\n")

        installSignalHandler()

        let consumerTask = Task { await self.consumeLoop() }

        for s in sources {
            segmenters[s.name] = Segmenter(source: s.name)
            let capture = CoreAudioCapture(deviceID: s.deviceID, label: s.name) { [weak self] samples in
                guard let self else { return }
                Task { await self.handleSamples(source: s.name, samples: samples) }
            }
            captures.append(capture)
            do {
                try capture.start()
            } catch {
                print("FAILED to open '\(s.name)': \(error)")
            }
        }

        await consumerTask.value

        let dropped = await queue.droppedCount
        await writer.close(droppedChunks: dropped, transcriberError: fatalMessage)
        exit(fatalMessage == nil ? 0 : 1)
    }

    private func handleSamples(source: String, samples: [Float]) async {
        guard let segmenter = segmenters[source] else { return }
        await writer.recordSamples(source: source, seconds: Double(samples.count) / Config.sampleRate)
        for chunk in segmenter.feed(samples) {
            await writer.recordChunk(source: source)
            await queue.push(chunk)
        }
    }

    private func consumeLoop() async {
        while let chunk = await queue.next() {
            guard chunk.averageRMS >= Config.chunkAverageRMSThreshold else { continue }
            do {
                let lines = try await engine.transcribe(chunk.samples)
                for line in lines {
                    let text = spellingCorrector?.apply(line.text) ?? line.text
                    guard !isRepeatedFiller(source: chunk.source, text: text) else { continue }
                    await writer.emit(source: chunk.source, wallClockOffset: chunk.startedAt + line.offset, text: text)
                }
                consecutiveErrors = 0
            } catch {
                consecutiveErrors += 1
                await writer.status("transcription error on '\(chunk.source)': \(error)")
                if consecutiveErrors >= Config.maxConsecutiveErrors {
                    fatalMessage = "\(error)"
                    await writer.status("\nERROR: too many consecutive transcription errors, stopping")
                    requestStop()
                    break
                }
            }
        }
    }

    /// True if `text` (short, <= 3 words) matches one of the last 2 accepted
    /// lines for this source. Keeps the first occurrence of a short phrase,
    /// suppresses immediate repeats - a real short repeated utterance ("no,
    /// no, no") is rare and an acceptable loss against how often this pattern
    /// is actually silence/music hallucination.
    private func isRepeatedFiller(source: String, text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = normalized.split(separator: " ").count
        var recent = recentTextsBySource[source, default: []]
        defer {
            recent.append(normalized)
            if recent.count > 5 { recent.removeFirst(recent.count - 5) }
            recentTextsBySource[source] = recent
        }
        guard wordCount <= 3 else { return false }
        return recent.suffix(2).contains(normalized)
    }

    private func requestStop() {
        guard !stopRequested else { return }
        stopRequested = true
        for c in captures { c.stop() }
        systemTap?.stop()
        for (_, segmenter) in segmenters {
            if let chunk = segmenter.flushRemaining() {
                Task { await queue.push(chunk) }
            }
        }
        Task { await queue.close() }
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in
            print("\nStopping...")
            self?.requestStop()
        }
        src.resume()
        sigintSource = src
    }
}
