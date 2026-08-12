# Handoff: H.265 receive — implementation DONE, live H.265 blocked at frame assembly (device-side packetization interop)

Date: 2026-08-12 · From: implementation/debug session (tickets 01–07 + live diagnosis) · Repo: `/Users/alexstark/Projects/forks/Overlook` · Branch: `feature/h265-receive` · HEAD: `cb36037`, clean tree, nothing pushed.

## ✅ RESOLVED ADDENDUM (2026-08-12, same-day device-access session) — READ THIS FIRST

The diagnosis below is OBSOLETE in its conclusion (kept for history). With direct device
access (`docs/agents/comet-device-access.md`) the root cause was found and reproduced
deterministically in both directions:

**Root cause: encoder/SDP codec mismatch, not packetization.** The Janus watch's
`video_format` shapes ONLY the SDP (`us_rtpv_make_sdp in video_format N` — device log);
the actual encoder format follows kvmd (the volatile `config.json` key, which had been
silently dropped — encoder at `--venc-format=0`). Every failing live run received
**H.264 bits labeled H.265**: libwebrtc's RFC 7798 depacketizer parses them without
warnings, but `H26xPacketBuffer` never sees an HEVC VPS → silent infinite discard →
`framesReceived=0`, endless PLIs, watchdog fallback (which then works because the
encoder really was H.264). The earlier probe conclusion “the device honors the client
request” was wrong — only the SDP honors it.

**Evidence (all reproducible):**

1. Wire capture (`.scratch/h265-receive/tools/rtp_trace.py`, GStreamer webrtcbin via
   auth-free SSH tunnel to the Janus unix socket): with the encoder REALLY in H.265 the
   GL packetizer is textbook-correct — VPS+SPS+PPS as single-NALU packets sharing the
   IRAP's RTP timestamp, FU-fragmented IDR, marker on last packet only, 12/12 groups,
   at 2–20 Mbps, with and without rtx/extmap negotiation. **All packetization
   hypotheses (H1/H2/H3) refuted; GL's plugin is exonerated.** (One curiosity: when the
   client negotiates extmaps, the plugin adds a playout-delay extension `{min=0,max=0}`
   to every packet — harmless.)
2. `OverlookTests/H265LiveWireDiagnosticTests.swift` (env-gated diagnostic): the REAL
   `WebRTCManager` — full pipeline, policy, watchdog, decoder factory — against the same
   tunnel: **1000+ frames decoded and rendered at 2560x1440@60**, decoder created, zero
   PLIs, at up to ~2,200 pkts/s (the live failure rate). Client stack fully exonerated,
   including the repinned M150 binary and our VideoToolbox decoder — live, not just
   offline fixtures.
3. Mismatch reproduction: encoder forced to `--venc-format=0`, watch `video_format=1` →
   EXACT live-failure signature (SDP `includesH265=1`, packets flow, `framesReceived=0`,
   pliCount climbing, watchdog at 5.4 s, H.264 fallback renders immediately).
4. kvmd pyc introspection (rm10-1.9.0): `__streamer_set_params_handler` accepts
   `video_format` → **`POST /api/streamer/set_params?video_format=N` is the supported,
   client-driven fix** (kvmd restarts the streamer on param change, same as quality/fps).

**LIVE CONFIRMATION (2026-08-12, ~12:29):** operator connected Overlook — status bar
“H.265”, video running; device-side verified simultaneously (kvmd-managed ustreamer
`--venc-format=1`, 2560x1440@60 captured). Live H.265 works end-to-end with zero client
changes, as predicted. (Operator hit a one-off 403 first: stale auth token from an
earlier kvmd restart → password re-prompt + a typo; second attempt succeeded. Note kvmd
rate-limits logins: 10 attempts/600 s window, 600 s lockout.) Formal tickets 04–08
verify pass + issue 10 + instrumentation strip still pending.

**State after this session:** device restored as found (no stray processes, temp files
removed, `video_format: 1` in config — BDA restored it), tunnels closed. New tracker
issue `10-set-encoder-video-format-via-kvmd-api.md` (`ready-for-agent`) carries the
durable fix. With the config key currently 1, live H.265 in Overlook likely works TODAY
unchanged — but the key is volatile (see `docs/agents/comet-device-access.md`), so
ship issue 10 before calling tickets 04–08 done. Diagnostic assets kept: the rtp_trace
tool, the env-gated live-diagnostic tests (skipped unless `OVERLOOK_H265_WIRE_DIAG=1`),
and six app sources now also compiled into the test target for the manager-level test.
Re-run recipe: tunnel `ssh -N -L 8080:/run/kvmd/janus-ws.sock root@100.92.27.77` (+8188
for the tracer), start an encoder per the device-access doc, then
`TEST_RUNNER_OVERLOOK_H265_WIRE_DIAG=1 xcodebuild … -only-testing:OverlookTests/H265LiveWireDiagnosticTests test-without-building`.

---

## State in one paragraph

All 7 implementation tickets are DONE, reviewed (two-axis + 2 adversarial rounds), and green: 22 tests, Release build, app installed. Live H.264 works end-to-end including the new fallback/watchdog/auto-reconnect machinery (proven in live runs). Live H.265 does NOT flow yet — the client is **proven correct at every layer we control**; the wall is inside libwebrtc frame assembly fed by the GL Janus plugin's RTP packetization (details below, with the full evidence chain). A researcher run on the GL packetizer source may still be running/complete — check `subagent` children / `.pi-subagents/artifacts/` for `gl-janus-h265-packetizer-research` output. Next session gains device access via the BDA agent over intercom (operator will arrange) — making device-side capture/config possible without operator relay.

## Read first

1. This file, fully.
2. `.scratch/h265-receive/spec.md` + `CONTEXT.md` (glossary — binding vocabulary) + `docs/adr/0001-*.md`.
3. `.scratch/h265-receive/issues/` — 01–03 `done`, 04–08 `ready-for-human` (live verification), 09 `needs-triage` (playout-delay no-op discovery).
4. `docs/handoffs/2026-08-11-h265-receive-handoff.md` — build recipe + codesign/ATS steps + device facts + coordination rules (still binding: the Comet at 100.92.27.77 is a production tool; device-side needs go through operator/BDA — though the new session will receive direct access info via intercom).

## Commits this session (planning baseline was `1180242`)

`7589b07` test scaffolding+fixtures · `6a4c2a1` policy module · `705042c` H.265 decoder · `891ca55` WebRTC 151 bump · `60bf2f0` live wiring · `0afe064` fallback+watchdog · `1496ce5` preference UI · `a24fabf` review fixes (auto-reconnect on ICE loss, pref-change edge, fallback display timing, tracker labels) · `7381f2e` + `4cc88bb` lifecycle race fixes (connection-generation guards) · `5521725` **repin WebRTC 151→150 + binary guard test** · `cb36037` TEMPORARY [DEBUG-h265] instrumentation (remove when live H.265 works — grep `DEBUG-h265`).

## The live-H.265 diagnosis — evidence chain (do NOT re-derive)

Symptom: connect → status bar "H.265" → ~5s blank → watchdog fallback → "H.264 (fallback)" with working video (fallback machinery working exactly as designed).

Instrumented probe trail (stderr captures in `/tmp/overlook-stderr*.log`, latest `overlook-stderr3.log`):

1. Watch Request sends `video_format=1` ✓ → device offers SDP **with** H265 `profile-id=1` ✓ → our answer carries `rtpmap:97 H265/90000` ✓ → ICE connects ✓.
2. **The device honors the client request**: ~2,200 RTP pkts/s arrive (packetsReceived 705→9,297 over 4s — full 1440p60 H.265 stream). Client-driven design works; persistent device config is irrelevant to Overlook (see "Safari check" below).
3. libwebrtc's RFC 7798 depacketizer parses every packet — **zero** `Failed to parse payload` warnings at `RTCCallbackLogger` severity=warning.
4. **`framesReceived=0` forever**; endless `(video_receive_stream2.cc:906): No decodable frame … requesting keyframe`; pliCount climbs (device seemingly never satisfies the PLI in a way assembly accepts). Decoder factory `createDecoder` is NEVER called for H265 (decoder creation is lazy on first assembled frame) — our decoder never gets a chance.
5. Root cause #1 (fixed): original pin stasel **M151 ships without `rtc_use_h265`** — zero H265 strings in every slice (M150: 20, M146: 21). Repinned to exact 150.0.0; `WebRTCBinaryH265SupportTests` guards this forever. Identical live failure on M150 → led to deeper diagnosis.
6. Fable-5 fresh review (artifact `d0014587_reviewer_0_output.md`) verified against actual branch-heads/7889 (M150) source: field-trial gating REFUTED (`H26xPacketBuffer` is unconditional for H265 at M150; `WebRTC-Video-H26xPacketBuffer` trial gates H264 only), ObjC factory translation REFUTED, depacketizer install REFUTED. **Remaining wall: `H26xPacketBuffer` requires VPS+SPS+PPS in-band within the SAME assembled frame as the IRAP (h26x_packet_buffer.cc:153-165, 266-283 @7889) and discards silently otherwise.**
7. Our fixtures prove parameter sets exist at the **encoder memsink** (`ustreamer-dump`, VPS+SPS+PPS before every IDR, 14/14). What the **Janus plugin's packetizer** does with them on the wire is the open question — GL's packetizer sits between memsink and RTP.

### Safari cross-check — INCONCLUSIVE (cause found 2026-08-12)

Operator tried Safari→GL web UI: it did NOT come up H.265 this time. **Cause found by BDA 2026-08-12**: the `video_format` key had been silently DROPPED from `/etc/kvmd/user/config.json` (GL client config rewrite; see `docs/agents/comet-device-access.md`), so the web UI requested H.264. BDA restored `video_format: 1`. "Safari decodes this device's H.265 wire format" remains UNVERIFIED as a current fact until re-checked. Do not treat WebKit-tolerance as established.

## Hypotheses for the wall (ranked, untested)

1. GL packetizer sends VPS/SPS/PPS as separate RTP packets with a **different RTP timestamp** than the IDR slice (separate frame → H26xPacketBuffer never sees an in-AU IRAP → discards everything, silently). Fix would be device-side (packetizer) or protocol-level.
2. GL packetizer **strips** parameter sets from the RTP path entirely (and has no `sprop-*` fmtp — offer carries only `profile-id=1`). If so, NO libwebrtc client can ever work, and Safari-working-previously needs re-explaining (WebKit may accept out-of-band-less streams differently or the earlier success needs re-verification).
3. Parameter sets ARE in-AU but something subtler (e.g. AP aggregation quirk, donl/sprop assumptions) breaks assembly-continuity.

### Researcher findings (COMPLETE — full brief: `.pi-subagents/artifacts/04d3d513_researcher_0_output.md`; read it before device work)

The packetizer research superseded the ranking above. Key facts (primary-sourced, citations in the brief):

- **GL's ustreamer/Janus fork source is NOT published** (GPL request open, `gl-inet/glkvm` is Python kvmd only) — line-level certainty is unobtainable; empirical wire capture is the only path.
- **Upstream pikvm/ustreamer's packetizer shape would already satisfy libwebrtc**: one 90kHz timestamp per access unit (`us_rtpv_wrap()` computes `pts` once), every NALU as its own single-NALU RTP packet (no AP/STAP — and that's fine: libwebrtc accepts separate packets sharing the IDR's timestamp), marker bit on last NALU only. Upstream is H.264-only; every H.265 byte on the device is GL-authored. So this is likely a **GL regression vs the upstream shape**.
- **libwebrtc M150's rules (verified in source)**: (1) `H26xPacketBuffer::BeginningOfStream()` = `HasVps(packet)` — no in-band VPS ⇒ zero frames forever, silently; (2) an IRAP's timestamp group must contain VPS+SPS+PPS; (3) **out-of-band `sprop-*` is explicitly unsupported for H.265** — no field trial, no escape hatch.
- **Refined hypotheses**: **H1 (most likely): VPS/SPS/PPS never make it into the RTP stream** (stripped by GL's NALU filter or moved to `sprop-*` fmtp) — the only hypothesis yielding exactly `framesReceived=0`. H2: per-NALU timestamps put parameter sets in a different frame than the IDR — also yields 0. H3 (separate param-set AU with own marker) is argued AGAINST by `framesReceived=0` (those would assemble as frames).
- **Safari is NOT a valid oracle**: WebKit ships its own independently-written HEVC RFC 7798 stack with resilience patches feeding VideoToolbox, which tolerates parameter sets as a separate preceding AU. Safari working ≠ wire format is libwebrtc-acceptable.
- **Client-side workarounds**: essentially none worth doing (SDP-munge to H.264 = what our fallback already achieves gracefully; a GStreamer re-packetizing relay is out of product scope; insertable streams can't help — they sit downstream of the discarding buffer).
- **Device-side remedy (needs GL patch — no config flag exists; GL deliberately hides H.265, "patent issues" per staff forum post)**: keep VPS/SPS/PPS in-band with the IDR's timestamp, marker on last NALU — ~5-line diff in their `rtpv` H.265 branch if it diverged from upstream's shape.

Discriminating evidence to collect (device access: `docs/agents/comet-device-access.md`):

1. ~~Grep the plugin binary~~ **DONE (BDA, 2026-08-12)**: `libjanus_ustreamer.so` has `_rtpv_process_h265_nalu` + an H265 SDP template (`rtpmap H265/90000`, `fmtp profile-id=1`, **NO `sprop-*` attributes**), and NO strings suggesting param-set caching/re-injection — consistent with a naive forward-as-they-come packetizer. Rules out the "param sets moved to out-of-band `sprop-*`" variant of H1; H1-strip vs H2-timestamp-split remains open.
2. **Check the actual offer fmtp**: our probes log only `includesH265` — capture the full `m=video` section of the device's offer (one-line instrumentation addition in `handleOfferSDP`, or read it off the device). (Template says no `sprop-*`; confirm live offer matches.)
3. **Decisive: per-RTP-packet trace `(seq, timestamp, marker, NAL type = (b0>>1)&0x3F)`** via a non-libwebrtc client attached to the same Janus plugin (aiortc or `gst webrtcbin`) — discriminates H1/H2/H3 in one capture. Look for types 32/33/34 vs 19, timestamp equality, marker placement, and any type 48/49 usage. Tip (BDA): diff observations against upstream pikvm/ustreamer's `us_rtpv_wrap` (GPL, public, likely ancestor of GL's plugin) to localize the bug without GL source.
4. ~~Re-confirm the memsink AU shape on rm10-1.9.0~~ **DONE (BDA fixtures)**: memsink AUs arrive contiguous `[VPS SPS PPS IDR]` per keyframe — so if the wire splits them, the split happens inside the packetizer.
5. ~~Restore device `video_format: 1`~~ **DONE (BDA, 2026-08-12)** — and the Safari-H.264 mystery is SOLVED: something (likely the GL web UI/app) rewrote `/etc/kvmd/user/config.json` and dropped the `video_format` key entirely; streamer was back at `--venc-format=0`. `config.json` is volatile — see `docs/agents/comet-device-access.md`. Overlook is immune (it sends `video_format: 1` per watch request). Safari re-check still pending, sanity signal only, not an oracle.

## Live environment state

- `/Applications/Overlook.app` = instrumented Release build (HEAD `cb36037`) with ATS+codesign applied. Old app backed up at `~/Overlook-pre-h265-backup.app.disabled`. Stale LaunchServices registrations (DerivedData Debug build, /tmp builds) were unregistered — always launch `/Applications/Overlook.app` explicitly.
- Reinstall recipe (after every rebuild): build via the recipe in the 2026-08-11 handoff → `ditto` to /Applications → `plutil -insert NSAppTransportSecurity …` FIRST → `codesign --force -s -` framework then app. (Order matters: plist edit before final codesign.)
- To capture probes: launch via `nohup /Applications/Overlook.app/Contents/MacOS/Overlook 2> /tmp/overlook-stderr.log &` — NSLog goes to stderr unredacted (unified log redacts args as `<private>`).
- Verification loop commands (both green at HEAD): test = `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath /tmp/overlook-tests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test` · Release build same flags with `-configuration Release -derivedDataPath /tmp/overlook-build build`.
- Reference binaries for strings-comparison live at `/tmp/webrtc-m150/`, `/tmp/webrtc-m146/` (may not survive reboot; re-download from stasel releases if needed).

## Parked issues

- `-999 cancelled` on `/api/streamer/set_params` when toggling quality/fps mid-connection (operator hit once; likely rapid-request cancellation or session teardown racing settings write; NOT investigated). Also: the "custom" quality preset showed 40 fps — pre-existing from upstream Overlook.
- Issue 09 (`needs-triage`): `setPlayoutDelayHint:` reflection hack is a no-op on BOTH 109 and current binaries — candidate modern API `SetJitterBufferMinimumDelay` needs a deliberate bridge decision.
- Two pre-existing Release warnings (`ContentView.swift`, `CoreAudioDevices.swift`) — untouched, upstream.

## Coordination

- BDA session (pi-intercom, cwd `~/Library/CloudStorage/OneDrive-Personal/AI_Projects/BraindumpAssistant`) owns device-side state and mirrors milestones to Plane LAB-28. **Device access is now operator-authorized and documented in `docs/agents/comet-device-access.md`** (delivered via BDA intercom 2026-08-12; supersedes the ask-BDA-first rule) — device-side capture/inspection can be done directly (still: it's a production tool on the operator's work Mac; be conservative, never reboot/reconfigure without explicit approval, prefer read-only capture).
- Tooling quirks that held all session: tree-sitter/module_report fails on this repo's Swift (use grep+reads); pi-lens clangd shows false-positive ObjC errors (WebRTC headers not in its include path — xcodebuild is the authority); pbxproj object IDs are hand-allocated sequential hex — CHECK FOR COLLISIONS before adding (one collision cost a broken build this session); child workers on cortex-responses/openai-gpt-5.6-sol worked well for tickets, `anthropic/claude-fable-5` for hard review (cortex route to fable was unavailable).

## Next actions (in order)

1. ~~Collect the packetizer researcher's artifact~~ DONE — folded in above; read the full brief at `.pi-subagents/artifacts/04d3d513_researcher_0_output.md`.
2. Get device access from BDA via intercom; restore/verify device H.265 mode; re-run the Safari cross-check.
3. Discriminate the packetization hypotheses with on-device evidence (plugin source/binary, RTP capture). THEN decide the remedy: device-side plugin fix (coordinate via BDA/LAB-28), protocol workaround, or — worst case — accept H.264 until GL fixes packetization (Overlook already degrades gracefully and visibly).
4. When live H.265 flows: strip `[DEBUG-h265]` instrumentation (revert/adapt `cb36037`; grep the tag), rebuild, reinstall, complete tickets 04–07 live checkboxes and ticket 08 acceptance, mirror outcome to LAB-28 via BDA.
