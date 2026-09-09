# swift-transcribe

Live meeting transcription for macOS, built on [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
so transcription runs on the Apple Neural Engine + GPU instead of the CPU.

(With lots of help from Claude Code)

```
transcribe-mps record
Starting meeting transcription
  recording from: RODE NT-USB
  recording from: System Audio
loading whisper model 'large-v3-v20240930_turbo' (first run downloads it)
compute: mel: CPU+GPU, encoder: CPU+ANE (Neural Engine), decoder: CPU+ANE (Neural Engine)
model ready - listening

Transcribing live. Press Ctrl+C to stop.

[17:20:38] [RODE NT-USB] are
[17:20:36] [System Audio] I'm not gonna sugarcoat it. We're in a tight spot now do me a favor
[17:20:42] [System Audio] Imagine they're one of those people think that Digger Rockwell Satan himself. I want to stumble the harshest attacks I can experience
[17:20:48] [System Audio] expect from those folks who think that i'm a scum of yours
[17:20:54] [System Audio] all those folks might uh say that
[17:20:50] [RODE NT-USB] so
[17:21:03] [System Audio] i wouldn't expect that
[17:21:07] [System Audio] mr president 55 minutes ago my company informed me of the explosion on our rig
[17:21:16] [RODE NT-USB] and you
[17:21:12] [System Audio] massive water displacement and triggering a tsunami.
[17:21:17] [System Audio] Well, let's estimate casualties in the hundreds of thousands.
[17:21:20] [System Audio] Now, Digger here got us into this mess, and Digger's gonna dig us out.
[17:21:24] [System Audio] what the hell is that a thing is huge
[17:21:37] [RODE NT-USB] and
[17:21:36] [System Audio] Of course they all heap the blame on me.
[17:21:39] [System Audio] You just drowned half the damn continent.
[17:21:41] [System Audio] What the fuck you're gonna do, devil down?
[17:21:46] [System Audio] Mr. Rockwell is a man who would
[17:21:48] [System Audio] roast our children alive if he thought he could sell them for a dime.
[17:21:55] [System Audio] What would happen if I stopped drilling?
[17:21:56] [System Audio] You starve, you freeze to death, that's what?

============================================================
Session length : 0:01:51
Sources:
  - RODE NT-USB: 105s recorded, 10 chunks
  - System Audio: 89s recorded, 7 chunks
Transcript lines: 28
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
