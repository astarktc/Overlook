# Comet display/encoder exploration: macOS HiDPI via EDID, the 4K60 question, bitrate floors

**Date:** 2026-08-18/19 · **Device:** GL.iNet Comet GL-RM10, firmware rm10-1.9.0 · **Sources:** web research (Opus child, citations inline) + read-only on-device investigation (SSH + ustreamer binary disassembly). Operational distillation lives in `docs/agents/comet-device-access.md`; this file is the evidence record.

## Verdicts

1. **HiDPI ("looks like") scaling:** gated on PPI computed from the EDID physical-size bytes — fixable. Two routes (§Q1): pure-EDID 4K30, or Mac-side override keeping 1440p60.
2. **4K60:** hardware-impossible. Triple-locked by the LT6911C HDMI 1.4 receiver (binding), the RV1126B 4K30-class encoder, and the MIPI-CSI link budget (§Q2).
3. **Bitrate floor:** encoder runs H.265 **VBR** with min hardcoded to 0.25× target (→ ~5 Mbps sag on static screens at 20 Mbps). Hidden `/tmp/cbr` flag file flips it to **CBR**; `/tmp/bitrate` accepts live targets above kvmd's 20 Mbps clamp (§Q3). Validated live 2026-08-19: CBR held ~17 Mbps on a static screen (QP-floor-limited) vs ~5 before; user-visible text quality improvement confirmed.

---

## Q1 — macOS HiDPI/Retina scaling via EDID

### Mechanism

macOS has one HiDPI mechanism: a framebuffer 2× the logical ("looks like") size, raster-downscaled to the display's actual output timing. The wire carries the display's native/max EDID timing, not the "looks like" size (BetterDisplay wiki; apple.stackexchange 421858; confirmed by `system_profiler` on M5 Max: framebuffer 6720×3780, wire 3840×2160).

### The gate

HiDPI eligibility = PPI derived from **EDID physical-size bytes 0x15/0x16** (max H/V image size in cm; fallback: the DTD mm fields) vs native resolution. Observed working ≥ ~140 PPI (32" 4K); observed failing ≤ ~110 PPI; the oft-quoted "192 PPI" is folklore. Surfaced in `ioreg -r -t -c AppleCLCD2` as `MaxHorizontalImageSize`/`MaxVerticalImageSize`. After editing EDID bytes, recompute block checksum at 0x7f.

The Comet's stock 4K EDID claims **12×7 cm** (nonsense → no HiDPI); its QHD EDIDs imply ~110 PPI (below the gate). This is why scaling options never appear.

### Route A — pure EDID (no Mac-side changes)

Advertise 3840×2160 as preferred/native timing + a 27"-class physical size (`0x15/0x16` = `3c 22`, 60×34 cm ⇒ ~163 PPI); CTA extension with VIC 95/94; consistent DTD mm fields; fixed checksum. macOS then offers "looks like 2560×1440" (5120×2880 framebuffer) automatically. **Wire becomes 3840×2160@30** — trades 60 fps for HiDPI. Unaffected by the M4/M5 DCP regression (logical width ≤ 3360).

### Route B — keep 1440p60, Mac-side override

A native-2560×1440@60 EDID plus a host-side `scale-resolutions` override plist (`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>`, 12-byte entries `[BE u32 2·W][BE u32 2·H][BE u32 1]`, reboot; no SIP disable — working implementation: `paulhkang94/acuity`, verified on M4 + macOS 26.x). Wire stays **2560×1440@60**; framebuffer is 2× logical.

Honest caveat for both routes: pixels on the wire don't increase, so the gain is supersampled antialiasing (smoother text), not true Retina detail — further diluted by H.265 encoding. Keep EDID vendor/product IDs stable so overrides keep applying; don't impersonate Apple's vendor ID (privileges are AUX-negotiated, not EDID).

---

## Q2 — 4K60 is a hard hardware limit

- **SoC:** RV1126B-P (GL staff confirmation + `RV1126B` in glkvm source + on-device `/proc/device-tree/model` = "Rockchip RV1126B-P EVB V14 Board", Linux 6.1.141).
- **HDMI RX (the binding wall):** Lontium **LT6911C** (on-device i2c 1-002b, chipid 0x516; also in user-posted kernel logs). HDMI **1.4**: 3.4 Gbps/channel ≈ 340 MHz TMDS. 4K60 needs 594 MHz/18 Gbps (HDMI 2.0 + scrambling — that's the LT6911**UXC**, a different part). Physically cannot ingest 4K60.
- **Encoder:** RV1126B venc spec'd 3840×2160@30 (brief datasheet; real-world reports struggle to hold even that).
- **MIPI-CSI:** 4 lanes ≈ 6 Gbps < 4K60's ~9 Gbps.
- **Pipeline as configured:** v4l2 formats cap at 2560×1440 (the current EDID never offers 4K); 4K30 is the chip-theoretical max reachable by EDID swap.

GL.iNet's own branding is uniformly "4K@30FPS"; no official 4K60 statement exists. Conclusion: EDID/software can move between 1080p/1440p60/4K30-class modes, but **no software change yields 4K60**. Best 60 fps mode: 2560×1440@60 (current).

---

## Q3 — Bitrate / rate control

### Rockchip MPP semantics (web)

Rate-control modes CBR/VBR/AVBR/FIXQP(+QPMAP/CVBR on RV1126B). CBR: target decisive (encoder pads static content). VBR/AVBR: min/max decisive; AVBR's **min** governs static scenes. QP knobs (`rc:qp_max` etc.) are the quality-correct lever when modes can't change. Smart-P/SMTRC modes exist to shed bits on static content — the opposite of our goal.

### GL firmware reality (on-device, disassembly-verified)

- ustreamer 6.37 GL fork; CLI RC surface only `--h264-bitrate`, `--h264-gop`, `--venc-mode <smart|normal>` (smart = TSVC4 layered), `--dst-fps`, `--zero-delay`. No RC-mode/min-bitrate/QP flags.
- Default RC mode: **VBR** (H.264 enum 2 / H.265 enum 9), chosen at VENC init. FIXQP stubbed.
- **Hidden flag files** checked via `access()` at VENC init: `/tmp/cbr`, `/tmp/vbr`, `/tmp/avbr` override the RC mode (codec-appropriate enum); also present: `/tmp/rc1`–`/tmp/rc5`, `/tmp/tsvc2/3`, `/tmp/smart`, `/tmp/IsoBig`. Streamer restart required to take effect; `/tmp` is volatile across device reboots.
- **Live bitrate path:** ustreamer inotify-watches **`/tmp/bitrate`** (raw bps) and applies via `RK_MPI_VENC_SetChnAttr` without restart. Derived window hardcoded: min = 0.25×, max = 1.25× of target. Value `0` = REMB auto mode (receiver-estimated bandwidth drives the target). kvmd's API clamps `h264_bitrate` at 20000 kbps, but direct file writes are unclamped (encoder silicon rated to 100 Mbps).
- QP bounds are kernel rc_model defaults (i/p [10:51], frame-level fqp i[16:42] p[18:42]) — no exposed knob. This floor (~QP 16–18) is the firmware's quality ceiling.

### Validation (2026-08-19, live on the production device)

- `/tmp/cbr` + kvmd restart → `enRcMode: 8` (H.265-CBR) confirmed in log.
- Static screen: **~17 Mbps sustained** (vs ~5 Mbps VBR floor before) — QP-floor-limited, i.e. maximum static quality this firmware can produce. User-confirmed visible text improvement.
- Live retarget via `/tmp/bitrate`: 25 Mbps ("min 6250 max 31250") and 40 Mbps ("min 10000 max 50000") both accepted without restart. Wire rate on static/video content stayed ≤ ~17 Mbps — above ~20–25 Mbps the encoder is QP-floor-bound, so extra target is motion headroom only.
- Caveat: firmware 1.9.0 predates the 1.9.1 fix for "screen corruption at maximum bitrate with WebRTC FEC" (1.9.1 shipped ~2026-05-15). No corruption observed during the probes.
- Overlook re-pins `h264_bitrate=20000` through the kvmd API on every connect, which rewrites `/tmp/bitrate` to 20000000 — any higher target must be reapplied after connect (or the kvmd clamp raised in `override.yaml`, or Overlook taught to pin higher).

### Loose ends

- GL's LT6911C driver bug (1440p misread as 2562×1441 → signal rejected) is still open in 1.9.1; a custom EDID with clean /4-divisible CVT-RB timings may sidestep it.
- PiKVM's `kvmd-edidconf --import-display-ids` is not wired up on RM10 — EDID must be supplied as a blob.
- GL's ustreamer fork is unpublished (GPL requests open); all fork facts above come from on-device binary disassembly (`/tmp/comet-ustreamer.{bin,asm}` on the device, pulled read-only).
