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

## Guardrails (production device — it drives the operator's work Mac)

- Fine: reads, logs, sink dumps, codec flips via `config.json`, kvmd restarts (~15 s).
- Avoid: reboots without asking, firmware changes, touching `/etc/kvmd/user/ssl/`
  (freshly fixed cert), deleting `.bak-*` files.
- A kvmd restart interrupts the operator's keyboard/mouse to his work Mac — check
  `stream.clients` in the state endpoint or ask first if in doubt.
- Leave codec state as found (H.265) or report what you changed — the web UI in Safari is
  the operator's interim quality client.
