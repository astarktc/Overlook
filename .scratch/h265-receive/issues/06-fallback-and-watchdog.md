# 06 — Fallback + first-frame watchdog integration

**What to build:** The self-healing paths, wired from policy-module decisions into the live connection flow. Offer-based Fallback: when the offer lacks H.265, re-watch with H.264. First-frame watchdog: when H.265 negotiates but no decoded frame arrives within the timeout, fall back to H.264 — composed with the existing stream-health/frame-age machinery rather than new monitoring. Fallback memory is app-session-scoped: Automatic Reconnects (stream drop, device blip) go straight to H.264 while remembered; any Operator-Initiated Connect (device selection, manual reconnect, Codec Preference change) clears the memory and retries H.265 fresh. No timed cooldown (deliberately out of scope). The worst failure mode — black screen on the operator's daily driver — becomes a visible, self-healing downgrade.

**Blocked by:** 05 — Live H.265 end-to-end.

**Status:** ready-for-human

- [ ] Offer without H.265 results in a working H.264 stream with Negotiated Codec marked as a fallback
  - Pending operator verification against an operator-approved H.264-only offer.
- [ ] Watchdog: an H.265 negotiation that produces no decoded frame within the timeout falls back to a working H.264 stream automatically (verifiable by forcing a decode-starved condition in a test or via a debug hook; document the method)
  - Policy action and debug hook are automated/tested; pending operator verification of the live replacement stream.
- [ ] Automatic Reconnect during remembered fallback goes straight to H.264 — no repeated watchdog-timeout black screen
  - Policy and manager threading are automated/tested; pending operator verification of the live audio-device recovery path.
- [ ] Each kind of Operator-Initiated Connect clears fallback memory and retries H.265
  - All three policy inputs are matrix-tested; pending operator verification of live device-selection/manual-reconnect behavior and the Codec Preference UI supplied by ticket 07.
- [x] Fallback memory does not survive an app restart
- [ ] Explicit H.265 preference on an H.264-only offer degrades visibly rather than failing
  - Policy action is tested; pending operator verification with ticket 07's Codec Preference UI and an operator-approved H.264-only offer.
- [ ] All fallback branching lives in the policy module (already matrix-tested in 02); integration verified live and documented
  - Static inspection confirms policy-owned branching and manager action execution; pending operator verification of live integration.

## Comments

### Integration design

- `CodecSelectionPolicy` now emits a one-shot `CodecSelectionAction.reissueVideoWatchRequest` command for both offer-based and watchdog Fallback. `WebRTCManager` publishes the returned state and executes the command; it does not select a codec. The replacement H.264 offer produces no second action, so the call flow is initial H.265 Watch Request → unsupported/decode-starved transition → one H.264 Watch Request → answer replacement offer.
- The first-frame watchdog uses the existing one-second stream-health timer, `connectedIceTime`, and `lastVideoFrameTime`. Its timeout is **5 seconds**, the pre-existing initial-frame health threshold. This is intentionally longer than the 3-second post-frame stall threshold to allow ICE and hardware-decoder startup while bounding a decode-starved black screen.
- `renderFrame` atomically records the first decoded frame through the existing frame-age state and feeds `.firstDecodedFrameArrived` to the policy only for that first frame. When the existing initial-frame timeout fires, the same stream-health branch feeds `.watchdogFired`; no second timer or monitoring loop was added. A replacement Watch Request resets the existing initial-frame health window for the H.264 stream.
- Debug hook: build Debug and launch with `OVERLOOK_FORCE_DECODE_STARVATION=1`. While the policy has armed an H.265 first-frame watchdog, the manager suppresses its frame-arrival/health signals. Once policy emits Fallback, suppression turns off so H.264 replacement frames are observed normally. The hook is compiled inert in Release.
- Fallback memory remains a plain `WebRTCManager` property initialized to `.none`; `disconnect()` intentionally retains it, while app termination destroys it. There are no `UserDefaults` or other persistence writes for Fallback memory. The manager also retains the last Codec Preference so an audio-device Automatic Reconnect does not silently substitute Auto.

### Connect/reconnect call-site classification

| Call path | Trigger | Classification passed to policy |
| --- | --- | --- |
| `ContentView.connectToDevice` → `WebRTCManager.connect` | Operator selects/connects a device | Operator-Initiated Connect (`deviceSelection`) |
| `MenuBarAgent.connectSession` → `WebRTCManager.connect` | Operator selects/connects a device | Operator-Initiated Connect (`deviceSelection`) |
| `VideoSurfaceView` reconnect callbacks → `WebRTCManager.reconnect` | Operator presses reconnect | Operator-Initiated Connect (`manualReconnect`) |
| `WebUISettingsPanel.reconnectWebRTC` → `WebRTCManager.reconnect` | Operator presses “Reconnect WebRTC” | Operator-Initiated Connect (`manualReconnect`) |
| Audio-device disappearance debounce → private `reconnect` | Device blip without operator action | Automatic Reconnect; retained Codec Preference and session Fallback memory are threaded through |
| Video ICE `.failed`, or `.disconnected` beyond its grace period | Stream drop without operator action | Automatic Reconnect; retained Codec Preference and session Fallback memory are threaded through |
| Codec Preference change (ticket 07 caller) | Operator changes Codec Preference | Policy input is `operatorInitiatedConnect(.codecPreferenceChange)`; matrix-tested, live caller pending ticket 07 |

These are the manager's Automatic Reconnect call sites. A signaling-only failure still surfaces connection loss without initiating a separate retry.

### Automated verification

- The policy tests now assert watchdog arming/disarming, the re-watch action for both Fallback causes, and action consumption on the replacement offer/repeated watchdog event (no loop).
- Full CLI suite: 19 tests passed on 2026-08-11.
- Release build passed on 2026-08-11.
- Static grep found no `.h264`/`.h265` selection branch in `WebRTCManager`; the manager switches only on `CodecSelectionAction` to execute the policy command.
- Static grep found no persistence of `fallbackMemory`; its only non-test storage is the in-memory manager property.

### Pending operator verification scripts

Use only operator-approved devices/configuration. Do not read or write persistent device codec configuration from repo tooling.

1. **H.264-only offer / explicit H.265 Fallback**
   1. Build and launch the Debug app without the starvation hook: `env -u OVERLOOK_FORCE_DECODE_STARVATION /tmp/overlook-tests/Build/Products/Debug/Overlook.app/Contents/MacOS/Overlook`.
   2. Connect to an operator-approved H.264-only endpoint with Auto. Confirm the first request asks for H.265, the H.264-only offer causes exactly one replacement Watch Request with `"video_format": 0`, live video flows, and Negotiated Codec is `H.264 (fallback)`.
   3. After ticket 07 exposes Codec Preference, repeat with explicit H.265 and confirm the same visible, working Fallback rather than failure.

2. **Watchdog Fallback via the debug hook**
   1. Launch the Debug app with `OVERLOOK_FORCE_DECODE_STARVATION=1 /tmp/overlook-tests/Build/Products/Debug/Overlook.app/Contents/MacOS/Overlook`.
   2. Make an Operator-Initiated Connect to the production Comet in its current H.265 mode. Do not change device configuration.
   3. Confirm H.265 negotiates, no manager frame-arrival signal is accepted for 5 seconds, exactly one H.264 Watch Request (`"video_format": 0`) is sent, H.264 video then flows, and Negotiated Codec is `H.264 (fallback)`.

3. **Automatic Reconnect remembers Fallback**
   1. In the same hook-enabled app session, first complete script 2 so Fallback memory is `.h264`.
   2. Enable audio, select an operator-approved removable audio input/output, then unplug or otherwise make that selected device disappear to trigger the existing audio-device recovery reconnect.
   3. Confirm the first video Watch Request after recovery is immediately `"video_format": 0`, video resumes without another 5-second watchdog interval, and Negotiated Codec remains `H.264 (fallback)`.

4. **Operator-Initiated Connect clears remembered Fallback**
   1. In the same hook-enabled app session after script 2, press the video surface reconnect control. Confirm the new first Watch Request is `"video_format": 1`; because the hook is still active, another 5-second watchdog interval followed by visible H.264 Fallback proves H.265 was retried.
   2. Repeat by disconnecting and selecting the device again; confirm the same H.265-first behavior.
   3. After ticket 07 lands, change Codec Preference to Auto or H.265 and reconnect through that control; confirm H.265 is requested first and the remembered Fallback was cleared.
   4. Quit and relaunch normally (without the hook), connect again, and confirm the first Watch Request is H.265, proving Fallback memory did not survive app restart.

- Added ICE-loss Automatic Reconnect recovery. Video ICE `.failed` schedules recovery with 0.5/1/2-second backoff; `.disconnected` receives a 2-second grace period and is canceled if ICE recovers. Recovery is limited to three attempts, requires the explicit `shouldMaintainConnection` operator-intent flag and current device target, resets after the first decoded frame or any Operator-Initiated Connect, and is canceled by operator disconnect, app termination, or deinitialization. Each retry remains classified as Automatic Reconnect, so remembered Fallback continues through `CodecSelectionPolicy.connect` and the replacement H.264 offer publishes `H.264 (fallback)`. Live ICE-loss verification remains outstanding.
- Lifecycle race guards now use a monotonically increasing connection generation. Each connect attempt captures its generation, all async signaling/setup and failure paths bail when superseded, and teardown invalidates outstanding work before clearing shared resources.
- Video teardown now detaches both the generation-capturing frame renderer and the video view, then clears the track. Frame and size callbacks are delivered to the main actor and ignored unless their attached-track generation is still current, so an old queued frame cannot reset reconnect retries or disarm the new stream's first-frame watchdog.
