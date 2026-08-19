# Overlook fork — close-out report for BDA (2026-08-19)

**Audience:** BDA session (device-side state owner, Plane LAB-27/28).
**Purpose:** close out BDA's open item on Overlook. Everything below is merged to `main`
on the fork (`/Users/alexstark/Projects/forks/Overlook`, pushed to origin). This is the
summary; pointers go to the detailed records.

## What the fork accomplished (start → today)

1. **H.265 end-to-end** — hardware H.265 (HEVC) decode path built and shipped: custom
   VideoToolbox decoder module, live receive path, per-device codec preference UI,
   fallback watchdog (H.265→H.264 inside one connection), WebRTC pinned to M150 (M151
   dropped H.265). Live-confirmed against the Comet at 2560×1440@60 with device-side
   `venc-format=1` verified. Encoder-format pinning: Overlook sends kvmd `set_params`
   before each watch, immune to GL clients clobbering `config.json` (synced with LAB-29,
   no writer conflict).

2. **CPU/stutter fix** (the big one) — diagnosed a SwiftUI invalidation storm plus a
   per-frame main-actor hop in the video renderer. Fixed across tickets 01–07: telemetry
   coalescing/equality-gating, panel unmounting, window-chrome discipline, cheap settings
   construction, and a full renderer replacement (`AVSampleBufferDisplayLayer` engine, one
   lock acquisition per frame, zero main-thread work on the decode path). Result:
   stutter-immune even under deliberate main-thread stalls; a 7.6 h passive soak on the
   release build showed CPU ~5%, flat RSS, zero layout storms. Evidence:
   `.scratch/cpu-stutter/measurements.md`, `soak.log`.

3. **Codec-fallback stream-identity fix** (ticket 08) — a late frame from the abandoned
   H.265 stream could masquerade as the replacement stream's first frame and disarm the
   watchdog. Fixed with stream epochs + frame provenance; survived two rounds of
   adversarial review; fully test-pinned including a mutation-verified end-to-end test of
   the receipt-side revalidation. `.scratch/cpu-stutter/issues/08-*.md`.

4. **Comet stream-quality work** (durable device changes — the part BDA should record):
   - **CBR + 40 Mbps rate-control persistence deployed on the Comet:**
     `/etc/init.d/S97vencquality` (repo copy `.scratch/comet-quality/`) forces CBR via
     `/tmp/cbr`, sets `/tmp/bitrate` to 40 Mbps, and runs a 5 s guard loop that re-bumps
     Overlook's per-connect 20 Mbps API pin. Because `rcS` globs init scripts from the
     read-only lower rootfs before the overlay mounts, new `S??` files never autostart —
     so a one-line hook was added to `/etc/init.d/S98kvmd` `start()` (backup:
     `S98kvmd.bak-vencquality`). Verified live; reboot survival not yet observed (will
     confirm on the next natural reboot). User-visible win: static screens went ~5→17 Mbps
     (kernel QP-floor is the firmware quality ceiling).
   - **A firmware upgrade wipes all of this** — S97, the S98 hook, and possibly the EDID.
     Re-deploy from the repo copies after any upgrade.
   - Device confirmed on firmware **V1.9.1 release1** (`/etc/os-release` git-describe is
     misleading; `/etc/version` is the truth).

5. **HiDPI for the work Mac** — goal (larger, Retina-crisp text over the Comet, mirrored,
   wire staying 1440p60) achieved **client-side only**: a display-override plist on the
   work Mac + BetterDisplay. Verified: HiDPI 1920×1080 (4K backing framebuffer), mirrored,
   Overlook still streams 1440p60. **No device-side EDID change** — and important device
   knowledge: the LT6911C's EDID-override flash region behaves write-once
   (`lt6911c_upgrade -e` silently no-ops on non-blank flash); do not attempt EDID
   reflashes without the full `-f` firmware-erase dance. 4K60 is hardware-impossible
   (LT6911C = HDMI 1.4). Details: `docs/research/2026-08-18-comet-hidpi-4k60-bitrate.md`,
   `docs/agents/comet-device-access.md`.

## Device-side ledger for BDA (deltas since BDA's last known state)

| Item | State |
|---|---|
| `/etc/init.d/S97vencquality` | NEW (CBR + 40 Mbps + guard loop) |
| `/etc/init.d/S98kvmd` | one-line hook added in `start()`; backup `S98kvmd.bak-vencquality` |
| EDID in LT6911C | unchanged (still ViewSonic VX2478-2 blob from Aug 8); flash region effectively write-once |
| `/etc/kvmd/user/config.json` `video_format` | unchanged policy: Overlook self-pins per watch |
| Firmware | V1.9.1 release1 (latest as of 2026-08-19) |

## Status

All Overlook development items are **closed**. No open tickets, all tests green (65),
main pushed. Only passive watch item: confirm S97vencquality survives the Comet's next
natural reboot. BDA can close its Overlook tracking item; suggest mirroring the ledger
above to LAB-28.
