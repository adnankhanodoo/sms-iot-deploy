#!/usr/bin/env python3
"""
server.py — Voice WebSocket server using sounddevice (PulseAudio-backed).
Replaces PyAudio which crashes on Ubuntu without JACK/OSS.

Install deps:
    pip install websockets sounddevice numpy opuslib

Run:
    pulseaudio --start          # ensure PulseAudio is up first
    python3 server.py
"""

import asyncio
import threading
import queue
import logging
import sys

import numpy as np
import sounddevice as sd
import websockets

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

# ── Audio config ────────────────────────────────────────────────────────────
SAMPLE_RATE    = 16000   # Hz  — narrowband voice, saves bandwidth
CHANNELS       = 1       # Mono
FRAME_DURATION = 40      # ms per frame
FRAME_SIZE     = int(SAMPLE_RATE * FRAME_DURATION / 1000)  # 640 samples
DTYPE          = "int16"

# ── Queues (thread-safe bridge between audio threads and async WS) ───────────
playback_queue = queue.Queue(maxsize=100)   # PCM int16 numpy arrays to play
capture_queue  = queue.Queue(maxsize=100)   # PCM int16 bytes to send

# ── Try to import opuslib; fall back to raw PCM if unavailable ───────────────
try:
    import opuslib
    USE_OPUS = True
    logger.info("Opus codec: ENABLED")
except ImportError:
    USE_OPUS = False
    logger.warning("opuslib not found — sending raw PCM16 (higher bandwidth)")


def list_devices():
    """Print available audio devices for debugging."""
    logger.info("Available audio devices:\n%s", sd.query_devices())


# ── Playback thread ──────────────────────────────────────────────────────────
def audio_player():
    """Drains playback_queue and writes PCM frames to the default output."""
    decoder = opuslib.Decoder(SAMPLE_RATE, CHANNELS) if USE_OPUS else None

    def callback(outdata, frames, time_info, status):
        if status:
            logger.debug("Playback status: %s", status)
        try:
            raw = playback_queue.get_nowait()
            if USE_OPUS:
                pcm_bytes = decoder.decode(raw, FRAME_SIZE)
                pcm = np.frombuffer(pcm_bytes, dtype=np.int16)
            else:
                pcm = np.frombuffer(raw, dtype=np.int16)

            if len(pcm) < frames:
                pcm = np.pad(pcm, (0, frames - len(pcm)))
            outdata[:] = pcm[:frames].reshape(-1, 1)
        except queue.Empty:
            outdata.fill(0)   # play silence when no data

    logger.info("Starting playback stream (device: default output)")
    with sd.OutputStream(
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype=DTYPE,
        blocksize=FRAME_SIZE,
        callback=callback,
    ):
        threading.Event().wait()   # block forever; callback drives playback


# ── Capture thread ───────────────────────────────────────────────────────────
def audio_capturer():
    """Reads frames from the default microphone input and fills capture_queue."""
    encoder = None
    if USE_OPUS:
        encoder = opuslib.Encoder(SAMPLE_RATE, CHANNELS, opuslib.APPLICATION_VOIP)
        encoder.bitrate = 12000   # 12 kbps — works on 2G/3G
        encoder.dtx = True        # silence uses ~1 kbps

    def callback(indata, frames, time_info, status):
        if status:
            logger.debug("Capture status: %s", status)
        pcm_bytes = indata[:, 0].tobytes()
        if USE_OPUS:
            try:
                encoded = encoder.encode(pcm_bytes, FRAME_SIZE)
                if not capture_queue.full():
                    capture_queue.put(encoded)
            except Exception as e:
                logger.warning("Encode error: %s", e)
        else:
            if not capture_queue.full():
                capture_queue.put(pcm_bytes)

    logger.info("Starting capture stream (device: default input)")
    with sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype=DTYPE,
        blocksize=FRAME_SIZE,
        callback=callback,
    ):
        threading.Event().wait()   # block forever


# ── WebSocket: send captured audio to client ─────────────────────────────────
async def send_audio(websocket):
    loop = asyncio.get_event_loop()
    while True:
        try:
            data = await loop.run_in_executor(
                None, lambda: capture_queue.get(timeout=1)
            )
            await websocket.send(data)
        except queue.Empty:
            continue
        except websockets.exceptions.ConnectionClosed:
            break


# ── WebSocket: receive audio from client → playback ──────────────────────────
async def handler(websocket):
    addr = websocket.remote_address
    logger.info("Client connected: %s", addr)
    send_task = asyncio.create_task(send_audio(websocket))
    try:
        async for message in websocket:
            if isinstance(message, bytes) and not playback_queue.full():
                playback_queue.put(message)
    except websockets.exceptions.ConnectionClosed:
        logger.info("Client disconnected: %s", addr)
    finally:
        send_task.cancel()


# ── Main ──────────────────────────────────────────────────────────────────────
async def main():
    list_devices()

    # Start audio threads as daemons (die with the main process)
    threading.Thread(target=audio_player,   daemon=True, name="player").start()
    threading.Thread(target=audio_capturer, daemon=True, name="capturer").start()

    logger.info("WebSocket server listening on ws://0.0.0.0:8765")
    async with websockets.serve(handler, "0.0.0.0", 8765):
        await asyncio.Future()   # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Server stopped.")
        sys.exit(0)
