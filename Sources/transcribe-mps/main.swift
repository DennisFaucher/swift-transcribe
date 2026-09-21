import Foundation

func flagValue(_ args: [String], _ name: String, default def: String? = nil) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return def }
    return args[idx + 1]
}

func printUsage() {
    print("""
    Usage: transcribe-mps <command> [options]

    Commands:
      devices                               List audio input devices
      models [--model NAME]                 Download and load a WhisperKit model, report timings
      bench <file.wav> [--model NAME] [--language LANG] [--repeat N]
                                             Benchmark transcription speed on a WAV file
      record [--mic NAME] [--speakers NAME] [--model NAME] [--language LANG] [--initial-prompt TEXT] [--outdir DIR] [--spelling FILE]
                                             Live meeting transcription (mic + system audio tap)

    Options:
      --mic NAME         Substring match for the mic input device (default: \(Config.defaultMicSubstring))
      --speakers NAME    Substring match for the output device to tap for system audio
                         (default: the system default output device; set this when your
                         mic and speakers are the same Bluetooth device, e.g. earbuds)
      --spelling FILE    Two-column (tab or comma separated) misspelling -> correct spelling
                         list applied to transcribed text, e.g. "Sincora\tCencora"
                         (default: \(Config.defaultSpellingFile), if present in the current directory)
      --model NAME       WhisperKit model variant (default: \(Config.defaultModel))
      --language LANG    Language code, or 'auto' (default: \(Config.defaultLanguage))
      --initial-prompt TEXT  Context hint given to Whisper
      --outdir DIR       Where to write session transcripts (default: transcripts)
      --repeat N         Repeats per chunk length for bench, first is warmup (default: 3)
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    printUsage()
    exit(2)
}

let rest = Array(arguments.dropFirst())
let model = flagValue(rest, "--model", default: Config.defaultModel)!
let language = flagValue(rest, "--language", default: Config.defaultLanguage)

switch command {
case "devices":
    do {
        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
        func padLeft(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
        }
        let devices = try CoreAudioDevices.listInputs()
        print("\(padLeft("Idx", 3))  \(pad("Name", 34)) \(padLeft("In", 2))  \(padLeft("Rate", 7))")
        print(String(repeating: "-", count: 60))
        for (i, d) in devices.enumerated() {
            print("\(padLeft("\(i)", 3))  \(pad(d.name, 34)) \(padLeft("\(d.channels)", 2))  \(padLeft("\(Int(d.sampleRate))", 7))")
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }

case "models":
    do {
        let engine = TranscriptionEngine()
        print("loading model '\(model)'...")
        let result = try await engine.load(model: model, language: language, verbose: true)
        print("loaded in \(String(format: "%.1f", result.loadSeconds))s")
        print("model folder: \(result.modelFolder)")
        print("compute: \(result.computeSummary)")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }

case "bench":
    guard let path = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: bench requires a path to a .wav file")
        exit(2)
    }
    let repeats = Int(flagValue(rest, "--repeat", default: "3")!) ?? 3
    do {
        try await Bench.run(path: path, model: model, language: language, repeats: repeats)
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }

case "record":
    let mic = flagValue(rest, "--mic", default: Config.defaultMicSubstring)!
    let speakers = flagValue(rest, "--speakers")
    let spelling = flagValue(rest, "--spelling")
    let outdir = flagValue(rest, "--outdir", default: "transcripts")!
    let initialPrompt = flagValue(rest, "--initial-prompt")
    let session = Session(outdir: outdir, model: model, language: language, initialPrompt: initialPrompt, micSubstring: mic, speakersSubstring: speakers, spellingFile: spelling)
    await session.run()

default:
    print("Unknown command '\(command)'\n")
    printUsage()
    exit(2)
}
