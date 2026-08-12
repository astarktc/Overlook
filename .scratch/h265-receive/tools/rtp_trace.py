#!/usr/bin/env python3
"""Per-RTP-packet trace client for the GL-KVM Janus ustreamer plugin.

Purpose: discriminate the H.265 packetization hypotheses (H1 strip / H2
timestamp-split / H3 separate param-set AU) that block libwebrtc frame
assembly (H26xPacketBuffer). Speaks the same Janus dialect as Overlook
(create -> attach janus.plugin.ustreamer -> watch{video_format} -> answer
offer via "start" + jsep -> trickle), receives the decrypted RTP stream via
GStreamer webrtcbin, and logs (seq, timestamp, marker, NAL type) per packet.

Run (signaling via SSH unix-socket tunnel, no device auth needed):
  ssh -f -N -o ExitOnForwardFailure=yes \
      -L 8188:/run/kvmd/janus-ws.sock root@100.92.27.77
  /tmp/h265-trace-venv/bin/python rtp_trace.py \
      --url ws://127.0.0.1:8188 --video-format 1 --duration 12

Requires: brew gstreamer (webrtcbin, rtph265depay for caps), pygobject3,
websockets (venv: uv venv --system-site-packages + uv pip install websockets).

Output dir (default /tmp/h265-trace-<ts>/): offer.sdp, answer.sdp,
packets.jsonl, summary.txt. Read-only against the device; the encoder streams
only while this client's watch is up (same as any viewer).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import threading
import time
import uuid
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstWebRTC", "1.0")
gi.require_version("GstSdp", "1.0")
from gi.repository import GLib, Gst, GstSdp, GstWebRTC  # type: ignore[attr-defined]  # noqa: E402

import websockets  # type: ignore[import-not-found]  # noqa: E402

HEVC_NAL_NAMES = {
    19: "IDR_W_RADL",
    20: "IDR_N_LP",
    21: "CRA",
    32: "VPS",
    33: "SPS",
    34: "PPS",
    35: "AUD",
    39: "SEI_PREFIX",
    40: "SEI_SUFFIX",
    48: "AP",
    49: "FU",
}


def nal_name(t: int) -> str:
    if t in HEVC_NAL_NAMES:
        return HEVC_NAL_NAMES[t]
    if t <= 9:
        return f"TRAIL/slice({t})"
    return f"type{t}"


class Tracer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.outdir = Path(args.outdir)
        self.outdir.mkdir(parents=True, exist_ok=True)
        self.packets: list[dict] = []
        self.packets_lock = threading.Lock()
        self.loop: asyncio.AbstractEventLoop | None = None
        self.ws = None
        self.session_id: int | None = None
        self.handle_id: int | None = None
        self.webrtc = None
        self.pipeline = None
        self.first_rtp_at: float | None = None
        self.got_offer = asyncio.Event()
        self.done = asyncio.Event()
        self.t0 = time.monotonic()

    # ---------- Janus signaling ----------

    async def send_json(self, obj: dict) -> None:
        assert self.ws is not None
        await self.ws.send(json.dumps(obj))

    def send_json_threadsafe(self, obj: dict) -> None:
        assert self.loop is not None
        asyncio.run_coroutine_threadsafe(self.send_json(obj), self.loop)

    @staticmethod
    def txn() -> str:
        return uuid.uuid4().hex

    async def janus_request(self, obj: dict, pending: dict) -> dict:
        t = self.txn()
        obj["transaction"] = t
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        pending[t] = fut
        await self.send_json(obj)
        return await asyncio.wait_for(fut, 10)

    async def run(self) -> None:
        self.loop = asyncio.get_running_loop()
        pending: dict[str, asyncio.Future] = {}

        async with websockets.connect(
            self.args.url, subprotocols=["janus-protocol"], max_size=None
        ) as ws:
            self.ws = ws
            reader = asyncio.create_task(self.reader_task(pending))
            keepalive = asyncio.create_task(self.keepalive_task())
            try:
                resp = await self.janus_request({"janus": "create"}, pending)
                self.session_id = resp["data"]["id"]
                resp = await self.janus_request(
                    {
                        "janus": "attach",
                        "plugin": "janus.plugin.ustreamer",
                        "opaque_id": f"oid-{uuid.uuid4()}",
                        "session_id": self.session_id,
                    },
                    pending,
                )
                self.handle_id = resp["data"]["id"]
                print(f"[janus] session={self.session_id} handle={self.handle_id}")

                await self.send_json(
                    {
                        "janus": "message",
                        "body": {
                            "request": "watch",
                            "params": {
                                "orientation": 0,
                                "audio": False,
                                "video": True,
                                "mic": False,
                                "camera": False,
                                "video_format": self.args.video_format,
                            },
                        },
                        "transaction": self.txn(),
                        "session_id": self.session_id,
                        "handle_id": self.handle_id,
                    }
                )
                print(f"[janus] watch sent (video_format={self.args.video_format})")

                await asyncio.wait_for(self.got_offer.wait(), 15)
                # Capture runs until duration elapses after first RTP (or timeout).
                try:
                    await asyncio.wait_for(self.done.wait(), self.args.duration + 30)
                except asyncio.TimeoutError:
                    print("[warn] capture window timed out without completing")
            finally:
                keepalive.cancel()
                try:
                    if self.session_id:
                        await self.send_json(
                            {
                                "janus": "destroy",
                                "session_id": self.session_id,
                                "transaction": self.txn(),
                            }
                        )
                        await asyncio.sleep(0.3)
                except Exception:
                    pass
                reader.cancel()
                if self.pipeline is not None:
                    self.pipeline.set_state(Gst.State.NULL)

    async def keepalive_task(self) -> None:
        while True:
            await asyncio.sleep(25)
            if self.session_id:
                await self.send_json(
                    {
                        "janus": "keepalive",
                        "session_id": self.session_id,
                        "transaction": self.txn(),
                    }
                )

    async def reader_task(self, pending: dict) -> None:
        assert self.ws is not None
        async for raw in self.ws:
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                print(f"[warn] non-JSON signaling frame: {raw[:80]!r}")
                continue
            jtype = msg.get("janus")
            t = msg.get("transaction")
            if jtype in ("success", "error") and t in pending:
                fut = pending.pop(t)
                if not fut.done():
                    if jtype == "error":
                        fut.set_exception(RuntimeError(str(msg.get("error"))))
                    else:
                        fut.set_result(msg)
                continue
            if jtype == "event" and "jsep" in msg:
                jsep = msg["jsep"]
                if jsep.get("type") == "offer":
                    print("[janus] offer received")
                    self.handle_offer(jsep["sdp"])
                    self.got_offer.set()
                continue
            if jtype == "trickle":
                cand = msg.get("candidate", {})
                if cand.get("completed"):
                    continue
                if self.webrtc is not None and "candidate" in cand:
                    self.webrtc.emit(
                        "add-ice-candidate",
                        cand.get("sdpMLineIndex", 0),
                        cand["candidate"],
                    )
                continue
            if jtype in ("webrtcup", "media", "hangup", "slowlink"):
                print(f"[janus] {jtype}: {msg.get('reason', '')}")
                continue
            if jtype == "ack":
                continue
            # catch-all: errors and unexpected messages must be visible
            print(f"[janus] unhandled: {json.dumps(msg)[:300]}")

    # ---------- WebRTC (GStreamer) ----------

    def handle_offer(self, sdp_text: str) -> None:
        (self.outdir / "offer.sdp").write_text(sdp_text)
        video_section = sdp_text[sdp_text.find("m=video") :] if "m=video" in sdp_text else "(none)"
        print("---- offer m=video section ----")
        print(video_section.strip())
        print("-------------------------------")

        self.pipeline = Gst.Pipeline.new("trace")
        self.webrtc = Gst.ElementFactory.make("webrtcbin", "recv")
        self.webrtc.set_property("bundle-policy", GstWebRTC.WebRTCBundlePolicy.MAX_BUNDLE)
        self.pipeline.add(self.webrtc)
        self.webrtc.connect("on-ice-candidate", self.on_ice_candidate)
        self.webrtc.connect("pad-added", self.on_pad_added)
        self.webrtc.connect("notify::ice-connection-state", self.on_ice_state)
        self.webrtc.connect("notify::connection-state", self.on_conn_state)

        # Explicit recv transceiver so webrtcbin knows it may answer H265/97
        # (+ rtx/98) even though it has no H265 encoder.
        caps = Gst.Caps.from_string(
            "application/x-rtp,media=video,encoding-name=H265,clock-rate=90000,payload=97"
        )
        self.webrtc.emit(
            "add-transceiver", GstWebRTC.WebRTCRTPTransceiverDirection.RECVONLY, caps
        )
        self.pipeline.set_state(Gst.State.PLAYING)

        res, sdpmsg = GstSdp.SDPMessage.new_from_text(sdp_text)
        if res != GstSdp.SDPResult.OK:
            print("[fatal] failed to parse offer SDP")
            self.finish_threadsafe()
            return
        offer = GstWebRTC.WebRTCSessionDescription.new(
            GstWebRTC.WebRTCSDPType.OFFER, sdpmsg
        )
        promise = Gst.Promise.new_with_change_func(self.on_remote_set, None)
        self.webrtc.emit("set-remote-description", offer, promise)

    def on_remote_set(self, promise: Gst.Promise, _user_data) -> None:
        promise.wait()
        reply = promise.get_reply()
        if reply is not None:
            print(f"[gst] set-remote-description reply: {reply.to_string()}")
        if self.webrtc is None:
            return
        p = Gst.Promise.new_with_change_func(self.on_answer_created, None)
        self.webrtc.emit("create-answer", None, p)

    def on_answer_created(self, promise: Gst.Promise, _user_data) -> None:
        promise.wait()
        if self.webrtc is None:
            return
        reply = promise.get_reply()
        answer = reply.get_value("answer")
        if answer is None:
            print("[fatal] create-answer failed:", reply.to_string() if reply else None)
            self.finish_threadsafe()
            return
        self.webrtc.emit("set-local-description", answer, Gst.Promise.new())
        text = answer.sdp.as_text()
        if self.args.mimic_libwebrtc:
            text = self.mimic_libwebrtc_answer(text)
            print("[munge] answer sent to Janus mimics libwebrtc (rtx + extmaps)")
        (self.outdir / "answer.sdp").write_text(text)
        vid = text[text.find("m=video") :] if "m=video" in text else "(none)"
        print("---- answer m=video section ----")
        print(vid.strip())
        print("--------------------------------")
        self.send_json_threadsafe(
            {
                "janus": "message",
                "body": {"request": "start"},
                "transaction": self.txn(),
                "session_id": self.session_id,
                "handle_id": self.handle_id,
                "jsep": {"type": "answer", "sdp": text},
            }
        )
        print("[janus] answer sent")

    @staticmethod
    def mimic_libwebrtc_answer(text: str) -> str:
        """Make the answer Janus sees look like libwebrtc's: accept rtx pt 98
        and the two header extensions the device offers. Only the copy sent to
        Janus is munged; webrtcbin's local description stays untouched (the
        media still arrives on pt 97 and parses fine; rtx pt 98 only appears
        on retransmissions)."""
        lines = text.replace("\r\n", "\n").split("\n")
        out: list[str] = []
        for line in lines:
            if line.startswith("m=video ") and " 98" not in line:
                line = line + " 98"
            out.append(line)
            if line.startswith("a=rtpmap:97 "):
                out.extend(
                    [
                        "a=rtpmap:98 rtx/90000",
                        "a=fmtp:98 apt=97",
                        "a=rtcp-fb:97 nack",
                        "a=rtcp-fb:97 goog-remb",
                        "a=extmap:1 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay",
                        "a=extmap:2 urn:3gpp:video-orientation",
                    ]
                )
        return "\r\n".join(out)

    def on_ice_candidate(self, _elem, mlineindex: int, candidate: str) -> None:
        print(f"[ice] local candidate (mline {mlineindex}): {candidate[:90]}")
        self.send_json_threadsafe(
            {
                "janus": "trickle",
                "candidate": {
                    "candidate": candidate,
                    "sdpMid": "0",
                    "sdpMLineIndex": mlineindex,
                },
                "transaction": self.txn(),
                "session_id": self.session_id,
                "handle_id": self.handle_id,
            }
        )

    def on_ice_state(self, elem, _pspec) -> None:
        print(f"[ice] ice-connection-state: {elem.get_property('ice-connection-state').value_nick}")

    def on_conn_state(self, elem, _pspec) -> None:
        print(f"[gst] connection-state: {elem.get_property('connection-state').value_nick}")

    def on_pad_added(self, _elem, pad: Gst.Pad) -> None:
        if self.pipeline is None:
            return
        caps = pad.get_current_caps()
        print(f"[gst] pad-added: {pad.get_name()} caps={caps.to_string() if caps else '?'}")
        if not pad.get_name().startswith("src"):
            return
        pad.add_probe(Gst.PadProbeType.BUFFER, self.rtp_probe, None)
        sink = Gst.ElementFactory.make("fakesink", None)
        sink.set_property("sync", False)
        sink.set_property("async", False)
        self.pipeline.add(sink)
        sink.sync_state_with_parent()
        pad.link(sink.get_static_pad("sink"))

    # ---------- RTP parsing ----------

    def rtp_probe(self, _pad, info, _user_data):
        buf = info.get_buffer()
        ok, mapinfo = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.PadProbeReturn.OK
        data = bytes(mapinfo.data)
        buf.unmap(mapinfo)
        rec = self.parse_rtp(data)
        if rec is not None:
            now = time.monotonic()
            if self.first_rtp_at is None:
                self.first_rtp_at = now
                print(f"[rtp] first packet: pt={rec['pt']} — capturing {self.args.duration}s")
            with self.packets_lock:
                self.packets.append(rec)
            if now - self.first_rtp_at >= self.args.duration:
                self.finish_threadsafe()
        return Gst.PadProbeReturn.OK

    def parse_rtp(self, d: bytes) -> dict | None:
        if len(d) < 12:
            return None
        v = d[0] >> 6
        if v != 2:
            return None
        pad = (d[0] >> 5) & 1
        ext = (d[0] >> 4) & 1
        cc = d[0] & 0x0F
        marker = (d[1] >> 7) & 1
        pt = d[1] & 0x7F
        seq = int.from_bytes(d[2:4], "big")
        ts = int.from_bytes(d[4:8], "big")
        ssrc = int.from_bytes(d[8:12], "big")
        off = 12 + 4 * cc
        ext_info = None
        if ext:
            if len(d) < off + 4:
                return None
            ext_profile = int.from_bytes(d[off : off + 2], "big")
            extlen = int.from_bytes(d[off + 2 : off + 4], "big")
            ext_data = d[off + 4 : off + 4 + 4 * extlen]
            ext_info = f"{ext_profile:04x}:{ext_data.hex()}"
            off += 4 + 4 * extlen
        end = len(d) - (d[-1] if pad and len(d) > off else 0)
        payload = d[off:end]
        rec = {
            "t": round(time.monotonic() - self.t0, 4),
            "seq": seq,
            "ts": ts,
            "m": marker,
            "pt": pt,
            "ssrc": ssrc,
            "plen": len(payload),
        }
        if ext_info is not None:
            rec["ext"] = ext_info
        if len(payload) <= 64:
            rec["hex"] = payload.hex()
        if len(payload) >= 2:
            ntype = (payload[0] >> 1) & 0x3F
            rec["nal"] = ntype
            if ntype == 49 and len(payload) >= 3:  # FU
                fu = payload[2]
                rec["fu_s"] = (fu >> 7) & 1
                rec["fu_e"] = (fu >> 6) & 1
                rec["fu_type"] = fu & 0x3F
            elif ntype == 48:  # AP
                inner = []
                o = 2
                while o + 2 <= len(payload):
                    ln = int.from_bytes(payload[o : o + 2], "big")
                    if o + 2 + ln > len(payload) or ln < 2:
                        break
                    inner.append((payload[o + 2] >> 1) & 0x3F)
                    o += 2 + ln
                rec["ap_nals"] = inner
        return rec

    def finish_threadsafe(self) -> None:
        assert self.loop is not None
        self.loop.call_soon_threadsafe(self.done.set)

    # ---------- Analysis ----------

    def describe(self, rec: dict) -> str:
        n = rec.get("nal")
        if n is None:
            return "?"
        if n == 49:
            se = ("S" if rec.get("fu_s") else "") + ("E" if rec.get("fu_e") else "")
            return f"FU[{se or '-'}] {nal_name(rec.get('fu_type', -1))}"
        if n == 48:
            return "AP[" + ",".join(nal_name(t) for t in rec.get("ap_nals", [])) + "]"
        return nal_name(n)

    def write_outputs(self) -> None:
        with self.packets_lock:
            packets = list(self.packets)
        jl = self.outdir / "packets.jsonl"
        with jl.open("w") as f:
            for rec in packets:
                f.write(json.dumps(rec) + "\n")

        lines: list[str] = []
        w = lines.append
        w(f"packets captured: {len(packets)}")
        if not packets:
            self.emit_summary(lines)
            return

        pts = sorted({p["pt"] for p in packets})
        w(f"payload types: {pts}")
        # effective NAL type per packet (FU start counts as its inner type)
        def eff_types(p: dict) -> list[int]:
            n = p.get("nal")
            if n is None:
                return []
            if n == 49:
                return [p["fu_type"]] if p.get("fu_s") else []
            if n == 48:
                return p.get("ap_nals", [])
            return [n]

        counts: dict[str, int] = {}
        for p in packets:
            for t in eff_types(p):
                counts[nal_name(t)] = counts.get(nal_name(t), 0) + 1
        w(f"NAL unit counts (FU counted at start): {json.dumps(counts, sort_keys=True)}")

        has_ps = any(t in (32, 33, 34) for p in packets for t in eff_types(p))
        w(f"parameter sets (VPS/SPS/PPS) present on the wire: {has_ps}")

        # timestamp grouping analysis
        ts_groups: dict[int, list[dict]] = {}
        for p in packets:
            ts_groups.setdefault(p["ts"], []).append(p)
        w(f"distinct RTP timestamps: {len(ts_groups)}")

        # keyframe (IRAP) groups
        irap_ts = sorted(
            ts
            for ts, grp in ts_groups.items()
            if any(t in (19, 20, 21) for p in grp for t in eff_types(p))
        )
        w(f"IRAP timestamp groups: {len(irap_ts)}")
        for ts in irap_ts[:6]:
            grp = sorted(ts_groups[ts], key=lambda p: p["seq"])
            types = [self.describe(p) + (" M" if p["m"] else "") for p in grp]
            head = types[:8]
            tail = types[-2:] if len(types) > 10 else []
            w(f"  ts={ts}: {len(grp)} pkts, seq {grp[0]['seq']}..{grp[-1]['seq']}: "
              + ", ".join(head) + (" ... " + ", ".join(tail) if tail else ""))
            in_group = {t for p in grp for t in eff_types(p)}
            w(f"    param sets IN this ts group: VPS={32 in in_group} SPS={33 in in_group} PPS={34 in in_group}")
            markers = [p["seq"] for p in grp if p["m"]]
            w(f"    marker on seq: {markers} (last seq in group: {grp[-1]['seq']})")

        # where do param sets live relative to IRAPs?
        ps_recs = [p for p in packets if any(t in (32, 33, 34) for t in eff_types(p))]
        if ps_recs:
            w("parameter-set packets (first 12):")
            for p in ps_recs[:12]:
                w(f"  seq={p['seq']} ts={p['ts']} m={p['m']} len={p['plen']} {self.describe(p)}"
                  + ("  <-- ts matches an IRAP group" if p["ts"] in irap_ts else "  <-- SEPARATE ts"))

        # markers per timestamp group (sample)
        multi_marker = sum(1 for grp in ts_groups.values() if sum(p["m"] for p in grp) > 1)
        no_marker = sum(1 for grp in ts_groups.values() if sum(p["m"] for p in grp) == 0)
        w(f"ts groups with >1 marker: {multi_marker}; with 0 markers: {no_marker} (of {len(ts_groups)})")

        # verdict
        w("")
        w("== VERDICT ==")
        if not has_ps:
            w("H1: parameter sets are ABSENT from the RTP stream (stripped by packetizer).")
        else:
            ps_in_irap = all(
                any(p["ts"] == ts for p in ps_recs) for ts in irap_ts
            ) if irap_ts else False
            ps_separate = any(p["ts"] not in irap_ts for p in ps_recs)
            if irap_ts and not ps_separate and ps_in_irap:
                w("Param sets share the IRAP timestamp group — wire looks libwebrtc-acceptable; "
                  "wall must be elsewhere (marker placement? re-check assembly).")
            elif ps_separate:
                w("H2/H3: parameter sets travel in a DIFFERENT timestamp group than the IRAP "
                  "(libwebrtc H26xPacketBuffer will never see an in-AU IRAP).")
        self.emit_summary(lines)

    def emit_summary(self, lines: list[str]) -> None:
        text = "\n".join(lines) + "\n"
        (self.outdir / "summary.txt").write_text(text)
        print()
        print(text)
        print(f"[out] {self.outdir}/offer.sdp answer.sdp packets.jsonl summary.txt")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8188")
    ap.add_argument("--video-format", type=int, default=1, help="0=H264 1=H265")
    ap.add_argument("--duration", type=float, default=12.0, help="capture seconds after first RTP")
    ap.add_argument("--mimic-libwebrtc", action="store_true",
                    help="munge the answer sent to Janus to accept rtx + extmaps like libwebrtc")
    default_outdir = time.strftime("/tmp/h265-trace-%Y%m%d-%H%M%S")
    ap.add_argument("--outdir", default=default_outdir)
    args = ap.parse_args()

    Gst.init(None)
    glib_loop = GLib.MainLoop()
    threading.Thread(target=glib_loop.run, daemon=True).start()

    tracer = Tracer(args)
    try:
        asyncio.run(tracer.run())
    except Exception as e:  # noqa: BLE001
        print(f"[fatal] {e!r}")
    finally:
        tracer.write_outputs()
        glib_loop.quit()


if __name__ == "__main__":
    main()
