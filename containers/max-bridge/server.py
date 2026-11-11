"""max-bridge: downlink audio -> Audio2Face-3D NIM gRPC -> blendshape fan-out.
v2 avatar plan Phase 1.

Wire dialect: nvidia_ace 1.2.0 controller.v1 (the documented protocol both
NIM 1.3 and 2.0 serve; NOT the PyPI nvidia-audio2face-3d 'AudioWithEmotionStream'
variant — mismatch discovered at build time 2026-11-11).

grpc.aio request streaming proved BROKEN against this proto pair in our
environment (cross-process, both grpcio 1.67 and 1.76: server receives one
truncated 12-byte request then EOF while the client generator lives). NVIDIA's
own interaction app uses the SYNC grpc API; we mirror that: the clip runs in
a thread, asyncio side exchanges via queues.

Protocol (WS on :8990):
  /feed   client -> bridge: first msg text JSON {"rate":24000}; then binary
          frames s16le PCM mono. Bridge keeps one live ProcessAudioStream,
          rotating the clip before the 300 s service cap; text {"eos":true}
          closes a clip; connection close ends the feed.
  /shapes bridge -> client: {"hello":true,"names":[...]} then frames
          {"t":unix_sec,"bs":{name:0..1}} (consumers clock on t; 30 fps).
While no audio arrives, 40 ms silence chunks keep the NIM stream healthy
(its low-fps rule drops streams under 29 fps for 7 s).
"""
import argparse
import asyncio
import json
import queue
import threading
import time

import grpc
import websockets
from nvidia_ace.a2f.v1_pb2 import AudioWithEmotion
from nvidia_ace.audio.v1_pb2 import AudioHeader
from nvidia_ace.controller import v1_pb2 as ctl
from nvidia_ace.services.a2f_controller.v1_pb2_grpc import (
    A2FControllerServiceStub)

CLIP_ROTATE_S = 240.0
SILENCE_CHUNK_MS = 40
_SENTINEL = object()


def make_header(rate: int):
    hdr = ctl.AudioStreamHeader()
    hdr.audio_header.CopyFrom(AudioHeader(
        audio_format=AudioHeader.AUDIO_FORMAT_PCM,
        channel_count=1, samples_per_second=rate, bits_per_sample=16))
    return hdr


class Bridge:
    def __init__(self, nim_url: str):
        self.nim_url = nim_url
        self.names: list[str] = []
        self.consumers: set = set()

    async def run_feed(self, ws):
        init = json.loads(await ws.recv())
        rate = int(init.get("rate", 24000))
        loop = asyncio.get_running_loop()
        out: asyncio.Queue = asyncio.Queue()
        inbox: queue.Queue = queue.Queue()

        def pump():  # asyncio ws -> thread-safe inbox
            async def _p():
                try:
                    async for msg in ws:
                        inbox.put(msg)
                except websockets.ConnectionClosed:
                    pass
                finally:
                    inbox.put(_SENTINEL)
            return asyncio.create_task(_p())

        def clip_worker():
            try:
                self._sync_clip(inbox, rate, out, loop)
            except Exception as e:  # noqa: BLE001
                loop.call_soon_threadsafe(out.put_nowait,
                                          {"error": repr(e)})

        pump_task = pump()
        worker = threading.Thread(target=clip_worker, daemon=True)
        worker.start()
        try:
            while True:
                item = await out.get()
                if item is None:
                    # clip ended: worker loop finished -> client gone or fatal
                    break
                if "error" in item:
                    print(f"[bridge] clip error: {item['error']}", flush=True)
                    break
                await self._fanout(json.dumps(item))
        finally:
            inbox.put(_SENTINEL)
            pump_task.cancel()
            worker.join(timeout=5)

    def _sync_clip(self, inbox, rate, out, loop):
        """One full feed session: rotates clips until sentinel/closed."""
        chan = grpc.insecure_channel(self.nim_url)
        stub = A2FControllerServiceStub(chan)
        try:
            while True:
                stop = threading.Event()

                def requests():
                    yield ctl.AudioStream(audio_stream_header=make_header(rate))
                    t0 = time.monotonic()
                    silence = b"\x00\x00" * (rate * SILENCE_CHUNK_MS // 1000)
                    while not stop.is_set():
                        try:
                            data = inbox.get(timeout=SILENCE_CHUNK_MS / 1000)
                        except queue.Empty:
                            data = silence
                        if data is _SENTINEL:
                            stop.set()
                            break
                        if isinstance(data, str):
                            if json.loads(data).get("eos"):
                                break
                            continue
                        yield ctl.AudioStream(
                            audio_with_emotion=AudioWithEmotion(audio_buffer=data))
                        if time.monotonic() - t0 > CLIP_ROTATE_S:
                            break
                    yield ctl.AudioStream(
                        end_of_audio=ctl.AudioStream.EndOfAudio())

                start_epoch = 0.0
                try:
                    for stream in stub.ProcessAudioStream(requests()):
                        # WhichOneof FIRST: touching an inactive oneof member on
                        # upb/protobuf>=4.24 messages silently kills the stream.
                        which = stream.WhichOneof('stream_part')
                        if which == 'animation_data_stream_header':
                            h = stream.animation_data_stream_header
                            if h.skel_animation_header.blend_shapes:
                                start_epoch = h.start_time_code_since_epoch
                                self.names = list(h.skel_animation_header.blend_shapes)
                                loop.call_soon_threadsafe(
                                    out.put_nowait,
                                    {"hello": True, "names": self.names})
                        elif which == 'animation_data':
                            skel = stream.animation_data.skel_animation
                            for bs in skel.blend_shape_weights:
                                if not bs.values:
                                    continue
                                loop.call_soon_threadsafe(
                                    out.put_nowait,
                                    {"t": start_epoch + bs.time_code,
                                     "bs": dict(zip(self.names, bs.values))})
                        elif which == 'status':
                            st = stream.status
                            if st.code != 0:
                                print(f"[bridge] NIM status: {st.code} {st.message}",
                                      flush=True)
                except grpc.RpcError as e:
                    print(f"[bridge] NIM clip rpc error ({e.code()}); "
                          "re-connecting in 1s", flush=True)
                    time.sleep(1.0)
                if stop.is_set():
                    break
        finally:
            chan.close()
            loop.call_soon_threadsafe(out.put_nowait, None)

    async def _fanout(self, msg: str):
        dead = set()
        for c in list(self.consumers):
            try:
                await c.send(msg)
            except Exception:
                dead.add(c)
        self.consumers -= dead


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nim", default="systemd-max-face:52000")
    ap.add_argument("--port", type=int, default=8990)
    args = ap.parse_args()
    bridge = Bridge(args.nim)

    async def handler(ws):
        path = ws.request.path
        if path == "/feed":
            await bridge.run_feed(ws)
        elif path in ("/shapes", "/", ""):
            # root = consumer too (client apps connect bare door URLs)
            bridge.consumers.add(ws)
            try:
                if bridge.names:
                    await ws.send(json.dumps({"hello": True, "names": bridge.names}))
                async for _ in ws:
                    pass
            finally:
                bridge.consumers.discard(ws)
        else:
            await ws.close(code=4404)

    async with websockets.serve(handler, "0.0.0.0", args.port, max_size=2**21):
        print(f"[bridge] listening :{args.port} nim={args.nim}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
