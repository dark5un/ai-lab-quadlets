"""Synthetic media tracks for the avatar bot: 640x480 animated test-pattern
video (VP8 via aiortc's encoder) and a sine-tone audio track (Opus).

No /dev/video* or audio devices are required — frames are generated in numpy.
aiortc encodes the raw AVFrames it receives, so this is a genuine encode path.
"""
from __future__ import annotations

import math
import time
from fractions import Fraction

import numpy as np
from aiortc import AudioStreamTrack, VideoStreamTrack
from aiortc.mediastreams import MediaStreamError
from av import AudioFrame, VideoFrame

VIDEO_W, VIDEO_H, VIDEO_FPS = 640, 480, 30
AUDIO_RATE, AUDIO_SAMPLES = 48_000, 480  # 10 ms frames, stereo s16


def _pattern_frame(t_s: float, frame_no: int) -> np.ndarray:
    """SMPTE-ish bars + moving sweep + frame counter — visibly animated."""
    x = np.arange(VIDEO_W, dtype=np.float64)
    y = np.arange(VIDEO_H, dtype=np.float64)
    # 7 vertical colour bars
    palette = [(192, 192, 192), (192, 192, 0), (0, 192, 192), (0, 192, 0),
               (192, 0, 192), (192, 0, 0), (0, 0, 192)]
    bar = (x.astype(int) * 7 // VIDEO_W).clip(0, 6)
    rgb = np.zeros((VIDEO_H, VIDEO_W, 3), dtype=np.uint8)
    for i, (r, g, b) in enumerate(palette):
        rgb[:, :, 0] += np.where(bar == i, r, 0).astype(np.uint8)
        rgb[:, :, 1] += np.where(bar == i, g, 0).astype(np.uint8)
        rgb[:, :, 2] += np.where(bar == i, b, 0).astype(np.uint8)
    # moving diagonal sweep (animation proof)
    sweep = ((x[None, :] + y[:, None] + int(t_s * 120)) % 240) > 220
    rgb[sweep] = (255, 255, 255)
    # bouncing box — easy to eyeball in a received stream
    bx = int((math.sin(t_s * 2.0) * 0.5 + 0.5) * (VIDEO_W - 60))
    by = int((math.cos(t_s * 1.5) * 0.5 + 0.5) * (VIDEO_H - 60))
    rgb[by:by + 40, bx:bx + 40] = (255, 80, 80)
    return rgb


class TestPatternVideoTrack(VideoStreamTrack):
    """Animated 640x480 test pattern at 30 fps.

    Pacing follows aiortc's own idiom (fixed pts grid + wait computed from
    pts) so encoder stalls never cause burst-emission.
    """

    kind = "video"

    async def recv(self) -> VideoFrame:
        pts, time_base = await self.next_timestamp()
        frame = VideoFrame.from_ndarray(
            _pattern_frame(pts / 90_000, self._timestamp // 3000 if hasattr(self, "_timestamp") else 0),
            format="rgb24",
        )
        frame.pts, frame.time_base = pts, time_base
        return frame


class SineAudioTrack(AudioStreamTrack):
    """440 Hz sine tone (Opus-encoded by aiortc), 10 ms packed-s16 stereo frames."""

    kind = "audio"

    SAMPLE_RATE = 48_000
    PTIME = 0.010

    def __init__(self, freq: float = 440.0, level: float = 0.25) -> None:
        super().__init__()
        self.freq = freq
        self.level = level

    async def recv(self) -> AudioFrame:
        if self.readyState != "live":
            raise MediaStreamError
        samples = int(self.SAMPLE_RATE * self.PTIME)
        if hasattr(self, "_timestamp"):
            self._timestamp += samples
            wait = self._start + (self._timestamp / self.SAMPLE_RATE) - time.time()
            if wait > 0:
                await _sleep(wait)
        else:
            self._start = time.time()
            self._timestamp = 0
        i = self._timestamp
        t = (np.arange(i, i + samples) / self.SAMPLE_RATE)
        wave = (np.sin(2 * np.pi * self.freq * t) * (32767 * self.level)).astype(np.int16)
        data = np.column_stack((wave, wave)).reshape(1, -1)  # interleaved packed s16 stereo
        frame = AudioFrame.from_ndarray(data, format="s16", layout="stereo")
        frame.pts = i
        frame.sample_rate = self.SAMPLE_RATE
        frame.time_base = Fraction(1, self.SAMPLE_RATE)
        return frame


async def _sleep(d: float) -> None:
    import asyncio
    await asyncio.sleep(d)
