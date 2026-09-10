# swift-transcribe

Live meeting transcription for macOS, built on [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
so transcription runs on the Apple Neural Engine + GPU instead of the CPU.

(With lots of help from Claude Code)

```
$ transcribe-mps record
Starting meeting transcription
  recording from: RODE NT-USB
  recording from: System Audio
loading whisper model 'large-v3-v20240930_turbo' (first run downloads it)
compute: mel: CPU+GPU, encoder: CPU+ANE (Neural Engine), decoder: CPU+ANE (Neural Engine)
model ready - listening

Transcribing live. Press Ctrl+C to stop.

[21:20:14] [System Audio] I've seen things you people wouldn't believe.
[21:20:22] [System Audio] Attack ships on fire.
[21:20:24] [System Audio] off shoulder of orian
[21:20:29] [System Audio] i've washed sea beams glitering the dark near to tenhousers gate
[21:20:45] [System Audio] so
[21:20:36] [System Audio] all those moments will be lost in time
[21:20:48] [System Audio] like tears in rain
[21:21:00] [System Audio] time to die
^C
Stopping...

============================================================
Session length : 0:01:39
Sources:
  - RODE NT-USB: 92s recorded, 11 chunks
  - System Audio: 92s recorded, 8 chunks
Transcript lines: 17
============================================================

```


## Why

This is a Swift rewrite of a Python meeting-transcription tool that used
[faster-whisper](https://github.com/SYSTRAN/faster-whisper)/CTranslate2. CTranslate2 has no
Metal/ANE backend on Apple Silicon at all - it only ever runs on the CPU, even when asked for
`mps`. WhisperKit runs Whisper as Core ML, so the encoder and decoder actually execute on the
Neural Engine and GPU.

A benchmark on a real recorded meeting showed WhisperKit (`large-v3-turbo`) at roughly
5-9x the real-time factor of the CPU/CTranslate2 path across the 2-12 second chunk lengths this
tool actually uses live.

## Requirements

- macOS 15 (Sequoia) or later, Apple Silicon recommended for ANE acceleration
- Xcode 16+ / Swift 6 toolchain
- A microphone and (optionally) something to capture system audio from - this uses a native
  Core Audio process tap (macOS 14.2+), not a virtual loopback driver like BlackHole

## Build

```sh
make build     # swift build (debug) + ad-hoc code-sign
# or
make release   # swift build -c release + ad-hoc code-sign
```

Code-signing isn't optional here: the binary embeds an `Info.plist`
(`NSMicrophoneUsageDescription` / `NSAudioCaptureUsageDescription`) via linker flags, and macOS's
TCC privacy system won't reliably grant (or even prompt for) microphone/system-audio permission
to an unsigned binary. Without a valid signature, the system-audio tap's `AudioDeviceStart` call
hangs indefinitely rather than failing or prompting.

## First run

Run `record` directly in a Terminal window (not from an automated/background context) the first
time, so you can see and approve any system permission dialog for audio capture:

```sh
.build/debug/transcribe-mps record
```

macOS attributes the permission request to the *responsible process* (your terminal app), so
once you approve it there, it persists for future runs.

## Usage

```
transcribe-mps <command> [options]

Commands:
  devices                               List audio input devices
  models [--model NAME]                 Download and load a WhisperKit model, report timings
  bench <file.wav> [--model NAME] [--language LANG] [--repeat N]
                                         Benchmark transcription speed on a WAV file
  record [--mic NAME] [--model NAME] [--language LANG] [--initial-prompt TEXT] [--outdir DIR]
                                         Live meeting transcription (mic + system audio tap)

Options:
  --mic NAME              Substring match for the mic input device (default: "RODE NT-USB")
  --model NAME            WhisperKit model variant (default: "large-v3-v20240930_turbo")
  --language LANG         Language code, or 'auto' (default: "en")
  --initial-prompt TEXT   Context hint given to Whisper
  --outdir DIR            Where to write session transcripts (default: "transcripts")
  --repeat N              Repeats per chunk length for bench, first is warmup (default: 3)
```

`record` writes `<outdir>/<timestamp>/transcript.md`, with lines formatted as
`[HH:MM:SS] [<source>] <text>`, live to both the console and the file. Press Ctrl+C to stop; it
flushes any in-progress audio, writes a session summary, and exits.

## Known limitations

- **No real VAD.** WhisperKit has no equivalent to faster-whisper's `vad_filter=True`
  (Silero VAD), so it occasionally hallucinates short filler phrases ("Thank you", "you",
  "The") on silence, room tone, or music. This is mitigated with a per-segment
  compression-ratio/no-speech-probability gate plus cross-chunk repeat suppression, but it's a
  heuristic, not a real speech classifier - some hallucination can still get through, and very
  quiet real speech can occasionally get filtered out with it.
- **Feature parity**: this only ports the core "always-on record" path from the Python tool.
  `--all-inputs`, `--exclude`, `--save-audio`, `--duration`, and a `doctor` health-check
  subcommand are not implemented.
- The system-audio tap replaces BlackHole/Multi-Output Device setups entirely - if you were
  relying on a BlackHole-based workflow, note this tool does not read BlackHole by name.

## Benchmarking against the Python/CPU path

`bench_python.py` is a faster-whisper counterpart to `transcribe-mps bench`, using identical
chunk lengths/repeat/warmup logic, for an apples-to-apples RTF/latency comparison:

```sh
uv run --with soundfile --with numpy bench_python.py <file.wav> --model turbo --repeat 3
```

## Credits

Built on [argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift)
(WhisperKit).
