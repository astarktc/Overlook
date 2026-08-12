# H.265 bitstream fixtures from the GL.iNet Comet (LAB-28 spike b)

Captured 2026-08-11 by the BDA session via passive `ustreamer-dump` of the live
H.265 memsink (`kvmd::ustreamer::h264`) on the Comet (fw rm10-1.9.0), while an
operator viewed the stream in the GL web UI.

Format: raw **Annex-B H.265** elementary stream · 2560x1440@60 · GOP 60 ·
RV1126B hw encoder ("normalp" mode, bitrate cap 20000 kbps) · 8-bit 4:2:0.

| File | Duration | SHA-256 |
| --- | --- | --- |
| `lab28-h265-sample.bin` | ~6s | `0d1897aa7ee6f566fb4b7c035f9de9f8eb5158f8b932f45007a6ea169f8c2664` |
| `lab28-h265-rejoin.bin` | ~8s | `03cd6d6cbcda3bd7323842bf74f1db7e299d8a9882dbe3f6f6c7ff0ab662c2e5` |

Verified NAL structure (both files): `[VPS(32) SPS(33) PPS(34) IDR_W_RADL(19)
TRAIL_R(1) ×59]` repeating each 1s GOP — parameter sets in-band before **every**
IDR (14/14 across both captures, zero exceptions). No CRA, no SEI.

Hashes were verified against the on-device originals at copy time and again before
promotion from the incoming drop zone. These files are committed test resources for
the `OverlookTests` target.
