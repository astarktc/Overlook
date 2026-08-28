# Comet device access (operator-authorized, 2026-08-12)

Direct device access is **operator-authorized for this repo's agent sessions** — this
supersedes the earlier "device-side needs go through operator/BDA" rule in the
2026-08-11/12 handoffs. Source: BDA session intercom brief, 2026-08-12 (Plane LAB-27/28).
BDA still owns device-side state tracking and mirrors milestones to LAB-28.

## Access

- SSH: `ssh root@100.92.27.77` (Tailscale; LAN alt `192.168.50.163`) — key-auth already
  works from this Mac. BusyBox/Buildroot shell, firmware rm10-1.9.0.
- File transfer: **no sftp-server — scp fails.** Use
  `cat file | ssh root@100.92.27.77 'cat > /path'` (and the reverse).
- Web UI: `https://100.92.27.77` (self-signed cert) — status bar shows negotiated codec +
  live bitrate.

## Codec / encoder state

- `/etc/kvmd/user/config.json` → `"video_format"` (0=H264, 1=H265; restored to 1 on
  2026-08-12). **A bare Janus watch request does NOT change the encoder** — its
  `video_format` shapes only the SDP the plugin offers (`us_rtpv_make_sdp`, verified
  2026-08-12). The encoder's real format follows kvmd: the config key at streamer start,
  or an authenticated `POST /api/streamer/set_params?video_format=N` (kvmd restarts
  ustreamer with `--venc-format=N` on param change — this is how the GL web UI switches
  codec, via its kvmd API session in parallel with its watch request).
- **`config.json` is VOLATILE** (BDA-confirmed 2026-08-12): GL clients can silently
  rewrite the file and DROP the `video_format` key entirely (prime suspect: the GL web
  UI/app persisting its own config model). Missing key → GL clients send H.264 in their
  watch request, and the `override.yaml` default does NOT protect that path (GL clients
  always send `video_format` explicitly). Overlook is immune as long as it keeps sending
  `video_format: 1` in its own watch request — the per-request value is what kvmd acts
  on. Verify the key on-device before relying on persisted state (this explains the
  earlier "Safari unexpectedly came up H.264" observation).
- Redundant default: `/etc/kvmd/override.yaml` has a `kvmd:streamer:video_format:1` block
  (backup: `override.yaml.bak-lab27`). Apply override edits with
  `/etc/init.d/S98kvmd restart` (~15 s outage).
- Live encoder state: `curl -s --unix-socket /run/kvmd/ustreamer.sock http://localhost/state`
  — **gotcha:** `encoder.type` says `RV1126-H264` even in H.265 mode (hardcoded label).
  Trust the process args instead:
  `cat /proc/$(pgrep -f "^kvmd/streamer")/cmdline | tr "\0" " "` → look for `--venc-format=1`.
- Logs: `logread | grep -iE "venc|streamer" | tail -20` (rc setup, IDR requests,
  resolution changes).
- Bitstream capture: `ustreamer-dump --sink kvmd::ustreamer::h264 --output /tmp/x.bin` —
  passive, but only produces data while a viewer has the stream up (encoder idles
  otherwise). **H.265 flows through the sink named "h264".**
- Janus: `/etc/kvmd/janus/*.jcfg`; plugin `/usr/lib/ustreamer/janus/libjanus_ustreamer.so`;
  WS at `/run/kvmd/janus-ws.sock` (nginx proxies `wss://<host>/janus/ws`).

## EDID (added 2026-08-19, see docs/research/2026-08-18-comet-hidpi-4k60-bitrate.md)

- EDID lives **in the LT6911C chip's flash**, not the filesystem. Apply at runtime via
  `POST /api/upgrade/edid` (hex string, exactly 128 or 256 bytes; 128-byte blobs get a canned
  CEA extension auto-appended; **no checksum validation** — don't flash garbage). Saved copy:
  `/etc/kvmd/user/edid.txt`; read back via `GET /api/upgrade/get_edid`. Applying resets the
  chip → the target Mac re-does display detection immediately.
- Current EDID (as of 2026-08-19): ViewSonic VX2478-2 identity, 2560×1440@60 preferred, no 4K
  modes, 300 MHz cap. Persists across reboots (chip flash); the boot script only re-flashes
  stock on first boot (`/etc/kvmd/user/edid_updated` guard).
- **4K60 is hardware-impossible** (LT6911C = HDMI 1.4). Do not chase it.

## Encoder rate control (added 2026-08-19, disassembly-derived)

- Default RC mode is **VBR** with min hardcoded to 0.25× target (→ static screens sag to ~5
  Mbps at the 20 Mbps target). **Flag files** read at VENC init (need a streamer restart, e.g.
  `/etc/init.d/S98kvmd restart`): `/tmp/cbr` / `/tmp/vbr` / `/tmp/avbr` force the RC mode.
  `/tmp` is volatile — flags vanish on device reboot.
- **`/tmp/bitrate`** (raw bps) is inotify-watched and applied live, no restart; window is
  0.25×/1.25× of the written value; `0` = REMB auto. It is NOT clamped — kvmd's API clamps at
  20000 kbps, direct writes don't. Overlook re-pins 20000 via the API on every connect,
  overwriting this file.
- CBR validated 2026-08-19: static screen holds ~17 Mbps (QP-floor-limited — kernel rc_model
  fqp floors ≈ 16–18 are the firmware's quality ceiling; no exposed knob). Targets above ~25
  Mbps only add motion headroom.
- **Persistence (deployed 2026-08-19):** `/etc/init.d/S97vencquality` (copy in repo:
  `.scratch/comet-quality/`) — at boot touches `/tmp/cbr`, sets `/tmp/bitrate` to 40 Mbps
  (window 10–50M), and runs a 5 s guard loop that bounces Overlook's per-connect 20 Mbps pin
  back to 40. Guard verified live. A firmware upgrade wipes it — re-deploy from the repo copy.
- Firmware version gotcha: the web UI reads `/etc/version` ("V1.9.1 release1" — correct),
  while `/etc/os-release` shows the git-describe `rm10-1.9.0-release1-5-g…` (5 commits after
  the 1.9.0 tag = the 1.9.1 build). Device is on **1.9.1 release1** (latest as of 2026-08-19),
  which includes the max-bitrate WebRTC-FEC corruption fix. On the next upgrade: `/tmp` flags
  and `S97vencquality` are wiped and the stock EDID may return — recheck all three.

## HiDPI on the target Mac (2026-08-19)

The work Mac (`ssh mac-uni-auto`, macOS 26.6.1) uses a `scale-resolutions` override plist for
the Comet's display identity (ViewSonic vendor `5a63` / product `2f34`) at
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5a63/DisplayProductID-2f34`
— installer + EDID backup in `.scratch/comet-quality/`. **The override's `DisplayProductName`
must stay "VX2478-2"** (renamed from "Comet KVM (HiDPI)" 2026-08-28): the override name is
what macOS — and the work Mac's MDM (Iru/Kandji) hardware inventory — reports for the
display, so it must match the wire EDID's ordinary-monitor identity, never "KVM"/"Comet".
(The wire EDID itself is immutable — see the reflash warning below — so the ViewSonic
identity is fixed; the Mac-side name is the only branding surface under our control.) Wire stays 2560×1440@60; macOS renders
a 2× framebuffer (supersampling). If the Comet's EDID identity ever changes, the override path
must change with it.

**Resolved 2026-08-19 (evening):** the override plist alone yields HiDPI modes that macOS's
System Settings won't classify as Retina (PPI gate from the EDID's claimed 53×30 cm physical
size), so the native scaled-resolution thumbnail UI never appears. Solution: **BetterDisplay**
(`brew install --cask betterdisplay`) on the work Mac — it exposes the override-created HiDPI
modes directly and works in mirrored mode. Verified working config: BetterDisplay HiDPI
1920×1080 → `system_profiler` reports "Resolution: 3840 x 2160, UI Looks like: 1920 x 1080 @
60.00Hz", mirroring on (Comet = master mirror), Overlook still streams 1440p60. Larger text,
Retina rendering, no device-side changes.

**Black stream + display missing from the work Mac's Displays settings (fixed 2026-08-28):**
macOS 26 can wedge a display into a persistent "rejected" state (BetterDisplay shows
"Not detected (past disconnected)"): hotplug events fire (built-in screen DPI-shuffles),
IOKit reads the EDID (`DisplayHints` shows VX2478-2), but WindowServer never onlines it —
and the state **survives reboots and power cycles** of Mac, dock, and Comet. Overlook then
faithfully streams the black no-output capture while status says "Connected H.265" (the
pipeline is fine — verify with the H265 live-wire diagnostic test if in doubt). Fix:
delete BOTH windowserver display prefs and reboot —
`/Library/Preferences/com.apple.windowserver.displays.plist` (sudo) and
`~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist` — cost is only
re-doing display arrangement prefs. Useful lever while diagnosing: force an HDMI hotplug
remotely with `echo 1 > /sys/bus/i2c/devices/1-002b/reset` on the Comet (also:
`hotplug_status` sysfs reads 0 even with an active link — don't trust it;
`resolution`/`real_resolution` go stale after signal loss — only a fresh dmesg
"Resolution:" line after reset proves live signal).

**Do NOT attempt EDID reflashing on the LT6911C** (the abandoned "option A"): the chip's
EDID-override flash region behaves write-once — `lt6911c_upgrade -e` reports success but the
served EDID never changes (verified through chip reset, device reboot, kvmd stopped, and HDMI
link down). Working theory: `-e` never erases (NOR flash semantics; only the `-f` firmware
path erases), and the ViewSonic blob flashed 2026-08-08 is now immutable to `-e`. A recovery
would require a full firmware reflash (`-f v3.bin`, risky on a production device) followed
immediately by `-e` — deemed not worth it now that BetterDisplay solves the goal. Details:
`docs/research/2026-08-18-comet-hidpi-4k60-bitrate.md`; patched EDID blobs + backup
(`edid-backup-2026-08-19.txt`) remain in `.scratch/comet-quality/`.

## Guardrails (production device — it drives the operator's work Mac)

- Fine: reads, logs, sink dumps, codec flips via `config.json`, kvmd restarts (~15 s).
- Avoid: reboots without asking, firmware changes, touching `/etc/kvmd/user/ssl/`
  (freshly fixed cert), deleting `.bak-*` files.
- A kvmd restart interrupts the operator's keyboard/mouse to his work Mac — check
  `stream.clients` in the state endpoint or ask first if in doubt.
- Leave codec state as found (H.265) or report what you changed — the web UI in Safari is
  the operator's interim quality client.
