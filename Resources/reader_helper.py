#!/usr/bin/env python3
"""reader_helper.py — the speech + article worker behind Hark's Read Aloud feature.

The app (ReaderEngine.swift) starts this once, with the private Python environment in
~/Library/Application Support/Hark/reader/venv, and keeps it running so the voice
model loads only once. It talks over stdin/stdout, one JSON object per line:

  request  {"id": 1, "op": "speak", "text": "...", "voice": "bm_george", "speed": 0.95, "out": "/path/1.wav"}
  reply    {"id": 1, "ok": true}                       (24 kHz mono 16-bit WAV written to "out")

  request  {"id": 2, "op": "extract", "url": "https://..."}
  reply    {"id": 2, "ok": true, "title": "...", "text": "..."}

  any failure  {"id": N, "error": "Type: message"}       (full traceback goes to stderr / helper.log)
  load failure {"fatal": "..."} and exit code 1

Requests are handled one at a time, in order. The helper exits when stdin closes,
so it never outlives the app.
"""

import argparse
import json
import os
import sys
import traceback
import wave

# Kokoro voice ids start with a language letter: a = American English, b = British English.
LANG_BY_PREFIX = {"a": "en-us", "b": "en-gb"}


def send(channel, message):
    """Writes one JSON reply line and flushes so the app sees it right away."""
    channel.write(json.dumps(message) + "\n")
    channel.flush()


def speak(kokoro, voices, request):
    """Synthesizes request["text"] and writes a WAV to request["out"].

    Writes to a temporary name first, then renames, so the app never sees a half-written file.
    Returns an empty dict (nothing extra to report).
    """
    import numpy as np

    voice = request["voice"]
    if voice not in voices:
        raise ValueError(f"unknown voice {voice!r}")
    lang = LANG_BY_PREFIX[voice[0]]
    samples, sample_rate = kokoro.create(request["text"], voice=voice, speed=float(request["speed"]), lang=lang)
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    out = request["out"]
    partial = out + ".part"
    with wave.open(partial, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm.tobytes())
    os.replace(partial, out)
    return {}


def extract(request):
    """Downloads a web page and returns its main article text (no menus, ads, or comments)."""
    import trafilatura

    url = request["url"]
    page = trafilatura.fetch_url(url)
    if page is None:
        raise RuntimeError(f"Could not download {url}. The site may block apps, or it may need a login.")
    text = trafilatura.extract(page, include_comments=False, include_tables=False)
    if not text:
        raise RuntimeError(f"Found no article text on {url}.")
    metadata = trafilatura.extract_metadata(page)
    # A page can genuinely have no title; the app then reads the text alone.
    title = metadata.title if metadata is not None and metadata.title else ""
    return {"title": title, "text": text}


def main():
    """Loads the voice model, then answers requests from stdin until it closes."""
    protocol = sys.stdout
    # why: libraries sometimes print; send all of that to stderr so stdout stays pure JSON.
    sys.stdout = sys.stderr

    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="path to kokoro-v1.0.onnx")
    parser.add_argument("--voices", required=True, help="path to voices-v1.0.bin")
    args = parser.parse_args()

    try:
        from kokoro_onnx import Kokoro

        kokoro = Kokoro(args.model, args.voices)
        voices = set(kokoro.get_voices())
    except Exception as error:
        traceback.print_exc()
        send(protocol, {"fatal": f"Could not load the voice model: {type(error).__name__}: {error}"})
        return 1

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request["id"]
            op = request["op"]
            if op == "speak":
                result = speak(kokoro, voices, request)
            elif op == "extract":
                result = extract(request)
            else:
                raise ValueError(f"unknown op {op!r}")
            send(protocol, {"id": request_id, "ok": True, **result})
        except Exception as error:
            traceback.print_exc()
            send(protocol, {"id": request_id, "error": f"{type(error).__name__}: {error}"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
