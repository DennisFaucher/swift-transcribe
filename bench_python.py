#!/usr/bin/env python3
"""Python-side counterpart to `transcribe-mps bench`, for an apples-to-apples
comparison against the existing faster-whisper/CTranslate2 CPU path. Chunking,
repeat/warmup, and reported metrics all mirror Bench.swift.

Usage:
    uv run --with faster-whisper --with soundfile bench_python.py <file.wav> \
        [--model turbo] [--language en] [--repeat 3]
"""

import argparse
import statistics
import sys
import time

import numpy as np
import soundfile as sf
from faster_whisper import WhisperModel

CHUNK_LENGTHS_SECONDS = [2, 6, 12, 30]
SAMPLE_RATE = 16_000

_REPO_MAP = {
    "tiny": "Systran/faster-whisper-tiny",
    "base": "Systran/faster-whisper-base",
    "small": "Systran/faster-whisper-small",
    "medium": "Systran/faster-whisper-medium",
    "large-v3": "Systran/faster-whisper-large-v3",
    "turbo": "mobiuslabsgmbh/faster-whisper-large-v3-turbo",
}


def load_mono_16k(path: str) -> np.ndarray:
    audio, sr = sf.read(path, dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        # simple linear resample - matches the Swift AVAudioConverter path closely
        # enough for a speed benchmark (this is not the accuracy-sensitive path).
        ratio = SAMPLE_RATE / sr
        n_out = int(len(audio) * ratio)
        x_old = np.linspace(0, 1, len(audio), endpoint=False)
        x_new = np.linspace(0, 1, n_out, endpoint=False)
        audio = np.interp(x_new, x_old, audio).astype(np.float32)
    return audio


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    idx = int((len(sorted_vals) - 1) * p)
    return sorted_vals[idx]


def bench_one_chunk_length(model, samples, chunk_seconds, language, repeats):
    chunk_len = int(chunk_seconds * SAMPLE_RATE)
    if chunk_len <= 0 or len(samples) < chunk_len:
        print(f"--- {chunk_seconds}s chunks: audio too short, skipping ---")
        return

    chunks = []
    start = 0
    while start + chunk_len <= len(samples):
        chunks.append(samples[start:start + chunk_len])
        start += chunk_len
    if not chunks:
        return

    print(f"--- {int(chunk_seconds)}s chunks ({len(chunks)} chunks x {repeats} repeats) ---")

    latencies_ms = []
    last_text = ""
    for run in range(repeats):
        for chunk in chunks:
            t0 = time.time()
            segments, _info = model.transcribe(
                chunk,
                language=language,
                beam_size=1,
                vad_filter=True,
                condition_on_previous_text=False,
            )
            texts = [s.text.strip() for s in segments]
            ms = (time.time() - t0) * 1000
            if run > 0:
                latencies_ms.append(ms)
            if run == repeats - 1:
                last_text += " ".join(texts) + " "

    if not latencies_ms:
        print("  (only 1 repeat requested - no warm timings collected)")
        return

    latencies_ms.sort()
    p50 = percentile(latencies_ms, 0.50)
    p95 = percentile(latencies_ms, 0.95)
    total_audio_seconds = len(chunks) * chunk_seconds
    total_decode_seconds = sum(latencies_ms) / 1000 / max(repeats - 1, 1)
    rtf = total_audio_seconds / max(total_decode_seconds, 0.001)

    print(f"  p50 {p50:.0f}ms  p95 {p95:.0f}ms  RTF {rtf:.2f}x")
    print(f"  sample text: {last_text.strip()[:160]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--model", default="turbo", choices=list(_REPO_MAP))
    ap.add_argument("--language", default="en")
    ap.add_argument("--repeat", type=int, default=3)
    args = ap.parse_args()

    print(f"loading '{args.path}'...")
    samples = load_mono_16k(args.path)
    total_seconds = len(samples) / SAMPLE_RATE
    print(f"  {len(samples)} samples @ {SAMPLE_RATE}Hz = {total_seconds:.1f}s")

    repo = _REPO_MAP[args.model]
    print(f"loading model '{args.model}' ({repo})...")
    t0 = time.time()
    model = WhisperModel(repo, device="cpu", compute_type="int8")
    print(f"  loaded in {time.time() - t0:.1f}s")

    language = None if args.language == "auto" else args.language
    for chunk_seconds in CHUNK_LENGTHS_SECONDS:
        bench_one_chunk_length(model, samples, chunk_seconds, language, args.repeat)


if __name__ == "__main__":
    sys.exit(main())
