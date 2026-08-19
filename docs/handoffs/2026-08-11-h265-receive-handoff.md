# Handoff: add H.265 (HEVC) WebRTC receive to Overlook

Date: 2026-08-11 · From: BraindumpAssistant session (device-side investigation, LAB-27/LAB-28) · To: the Overlook fork project agent

## Mission

Make this fork of Overlook decode **H.265 over WebRTC** from the GL.iNet Comet GL-RM1PE KVM, so the operator's daily-driver client gets the picture-quality win that is already **proven working end-to-end on the device side** (verified today via the GL web UI: "definitely better across the board" — sharper text, less gradient banding).

**Acceptance**: Overlook connects to the Comet (Tailscale `100.92.27.77`) and streams WebRTC H.265 at 2560x1440@60 with quality parity to the GL web UI's H.265 stream and latency parity to current Overlook H.264.

## Facts proven on the device today (do not re-derive)

- The Comet is a **PiKVM fork**: kvmd + GL's ustreamer fork (Rockchip RV1126B hw encoder) + **Janus** WebRTC gateway.
- The GL Janus plugin has full **H.265 RTP packetization + SDP offer** (`a=rtpmap H265/90000`, `fmtp profile-id=1`). Janus is the **offerer**.
- Codec selection is driven by the **client's Janus `watch` request**: the GL web UI sends `"video_format": 1` (enum `{H264:0, H265:1}`) in the watch `params`, and kvmd relaunches ustreamer with `--venc-format=1`. Verified in device logs: encoder at 20000 kbps (range 5000–25000), "normalp mode".
- Observed H.265 bitrate: ~12000+ kbps on motion, 3500–4500 static (H.264 baseline: ~3625 static). Same 20 Mbps ceiling (hard-capped in a kvmd validator).
- Both codecs are 8-bit **4:2:0** — chroma fringing on text is inherent either way; the H.265 win is real but comes from better transforms/SAO (banding) + more generous rate control.
- The device currently sits with `video_format: 1` in `/etc/kvmd/user/config.json` — i.e. **stock Overlook shows no video right now**; the GL web UI (Transfer: WebRTC) is the interim client and the reference implementation to mirror.

## Change surface in this codebase (sized 2026-08-11, baseline build green at e4f599e)

1. **SPM dependency** — `Overlook.xcodeproj` pins `stasel/WebRTC` at **109.0.1** (upToNextMajor). That build predates H.265 internals entirely (stasel enabled `rtc_use_h265=true` from release 146; current is ~150). Route decision below.
2. **Signaling** — `Overlook/WebRTCManager.swift` ~line 494: the Janus `watch` request's `params` dict lacks `video_format`. Add `"video_format": 1` (or a negotiated value). This alone makes the device encode H.265.
3. **Decode** — `Overlook/WebRTCFactoryBuilder.m` (ObjC bridge, already in the bridging header) constructs `RTCDefaultVideoEncoderFactory`/`RTCDefaultVideoDecoderFactory`. This is the seam for a custom decoder factory that advertises H265 and returns a VideoToolbox-backed decoder — needed on the stasel route because upstream's ObjC SDK ships **no** `RTCVideoDecoderH265` and its default factory advertises only H264/VP8/VP9/AV1 (declaring H265 against it crashes at runtime — LiveKit issue #734).

## Route decision (the first real fork in the road)

Full analysis: `docs/research/2026-08-11-h265-webrtc-macos-client-feasibility.md` (cited, primary-source). Summary:

- **Route A — swap to `livekit/webrtc-xcframework` (LKRTC symbols)**: their Apple SDK added HEVC in M137; least code. **Unverified gap**: whether the HEVC decoder is exposed on macOS (not iOS-only) through the default factory — check with `nm -gU`/headers before committing. Carries LiveKit-oriented patches; symbol rename cost across the codebase; almost certainly **not upstreamable**.
- **Route B — bump stasel to ≥150 + hand-write the decoder**: stasel builds `rtc_use_h265=true` since 146, so depacketizer/`H26xPacketBuffer` are in the binary; write `RTCVideoDecoderH265` (port HackWebRTC's 277-line `VTDecompressionSession` wrapper or WebKit's) + a factory advertising H265 `profile-id=1`. More code, fully upstreamable, keeps the existing dependency. Carry shiguredo's VPS `vps_max_num_reorder_pics` fix (WebKit hit the same bug — manifests as long time-to-first-frame).
- Either route: the 109→150 bump itself is a risk (41 majors of API drift; note the `setPlayoutDelayHint:` NSInvocation reflection hack in `WebRTCFactoryBuilder.m` — verify it still resolves).
- **Empirical spikes to run before/at spec time** (facts, not opinions):
  - (a) LiveKit xcframework macOS HEVC exposure check (~30 min).
  - (b) Does the Comet emit **in-band VPS/SPS/PPS on keyframes**? libwebrtc's H.265 depacketizer requires it ("remote endpoint must send sequence and picture information in-band"). The GL web UI working in Safari does NOT prove this — Safari uses WebKit's own stack. Packet capture or an early tracer-bullet test settles it.
- Licensing posture: **VideoToolbox (hardware) decode only** — the stance shiguredo validated with the patent pools. Do not link a software HEVC decoder.
- Prior art for negotiation UX: JetKVM shipped exactly this feature (jetkvm/kvm#1371 — Auto/H.265/H.264 preference, SDP capability check, H.264 fallback).

## Open product decisions (grill these, don't assume)

1. Hardcoded H.265 vs auto-negotiation vs a settings toggle in Overlook's UI?
2. **Upstream intent** — PR to rcawston/Overlook eventually? This decides Route A vs B almost by itself (a dependency swap to LKRTC is not upstreamable; a stasel bump + optional decoder is).
3. Fallback behavior when the device is in H.264 mode (config flag? SDP-driven? silent?).
4. Where does the device-side `video_format` flip live — does Overlook set it via the watch request only (device follows the client, as the web UI does), or should Overlook also expose the choice?

## Build & environment gotchas (inherited from the original install — LAB-21)

Rebuild recipe (works, used for today's baseline):

```bash
xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Release \
  -derivedDataPath /tmp/overlook-build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

After **every** rebuild that lands in `/Applications`:

1. `codesign --force -s - <app>/Contents/Frameworks/WebRTC.framework` then `codesign --force -s - <app>` — the embedded WebRTC binary carries its author's Team ID; ad-hoc app + hardened runtime aborts at launch otherwise (dyld "different Team IDs"). Applies to whichever WebRTC framework the route lands on.
2. `plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads":true}' <app>/Contents/Info.plist` — the KVM's cert is self-signed (valid 10-year cert since 2026-08-07, but untrusted); ATS hard-rejects in an app bundle even though the URLSession delegate accepts.

## Test target & coordination

- Device: GL.iNet Comet at `100.92.27.77` (Tailscale) / `192.168.50.163` (LAN), attached to the operator's **work Mac** — it is a production tool; don't reboot or reconfigure it casually.
- The **BraindumpAssistant session/project owns device-side state** (root SSH, key-auth). If you need the device flipped H.264↔H.265, or device logs (`logread | grep venc`), ask the operator or the BDA session (pi-intercom) rather than SSHing config changes yourself.
- Reference client behavior: GL web UI at `https://100.92.27.77` (self-signed cert) — status bar shows negotiated codec + live bitrate. Its SPA bundle (`/usr/share/kvmd/glweb/assets/`) is the ground truth for the watch-request shape.

## Tracking

- Lab-side (BDA Plane, not visible from this repo): **LAB-27** (quality initiative, umbrella) → **LAB-28** (this fork work). Day-to-day dev tracking lives here in-repo per the Matt Pocock convention (`.scratch/<feature>/issues/`); the BDA session mirrors milestone outcomes to LAB-28.
- Branch: `feature/h265-receive` (already created). Remotes: `origin` = astarktc/Overlook, `upstream` = rcawston/Overlook.

## Suggested flow from here

`/grill-with-docs` seeded with this file (short — settle the four open decisions; demand the two spikes as facts) → `/to-spec` → `/to-tickets` (spike tickets first, blocking the route-dependent ones) → `/implement` per ticket.
