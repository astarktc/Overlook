# Handoff: H.265 receive — root cause FIXED, one live verify pass left

Date: 2026-08-12 · From: root-cause + issue-10 session · Repo: `/Users/alexstark/Projects/forks/Overlook` · Branch: `feature/h265-receive` · HEAD: `c91d4b9`, clean tree, nothing pushed.

## State in one paragraph

The live-H.265 mystery is SOLVED and the durable fix is implemented, tested, and
installed. Root cause: the Janus watch's `video_format` shapes only the SDP; the encoder
follows kvmd's volatile config key, which had been silently dropped — so failing runs
received H.264 bits labeled H.265, which libwebrtc silently discards (no HEVC VPS →
`H26xPacketBuffer` never starts). GL's packetizer, the stasel M150 binary, our decoder,
and the whole Overlook pipeline were each exonerated with live evidence, and the failure
was reproduced deterministically both ways. Issue 10 (encoder pinning via authenticated
`set_params` before every watch request) is implemented at `202a1a3` and a fresh Release
build with it is installed at `/Applications/Overlook.app`. Live H.265 was confirmed
once by the operator (~12:29, on the pre-pin build, with the config key manually
restored). **Your job: the formal verify pass on the NEW build, then strip the
instrumentation and close out.** The operator wants a SINGLE session handling this —
do device-side observation YOURSELF (you have direct root access); BDA is only for
Plane mirroring over intercom.

## Read first

1. This file.
2. `docs/handoffs/2026-08-12-h265-live-debug-handoff.md` — the ✅ RESOLVED addendum at
   the top (root cause, evidence chain, diagnostic assets). History below it is obsolete
   in conclusion; skim only if curious.
3. `docs/agents/comet-device-access.md` — operator-authorized device access (SSH,
   codec/encoder state, capture, guardrails, config-volatility warning). Binding.
4. `.scratch/h265-receive/issues/10-*.md` — the fix you're verifying (all checked but
   the formal live-verify box). `04–08` carry the live checkboxes to complete;
   `09` (playout-delay no-op) stays parked.

## What the verify pass looks like

Precondition: operator relaunches Overlook (`/Applications/Overlook.app` — the NEW
build; his long-running old-build session doesn't have the pin) and connects. Keep his
attention cost near zero: you watch everything; ask him only what the screen shows.

1. **Before/at connect** — capture app logs. For probe visibility launch via
   `nohup /Applications/Overlook.app/Contents/MacOS/Overlook 2> /tmp/overlook-stderr.log &`
   (NSLog → stderr unredacted), or `log stream --predicate 'process == "Overlook"'`.
   Expect, in order: `[Overlook] encoder format pinned to video_format=1` →
   `[DEBUG-h265] sending video Watch Request video_format=1` → offer `includesH265=1` →
   decoder `createDecoder: name=H265` → `FIRST rendered frame`.
2. **Device-side (yourself, read-only)** — `ssh root@100.92.27.77`:
   - set_params arrival: `logread | grep -E "set_params|streamer"` (expect a POST from
     Overlook's UA, and NO encoder restart when the value is unchanged — idempotence).
   - encoder truth: `cat /proc/$(pgrep ustreamer)/cmdline | tr "\0" " " | grep -o "venc-format=[0-9]"`
     (the state endpoint's `encoder.type` label lies — always check cmdline).
   - optional corroboration: `ustreamer-dump --sink kvmd::ustreamer::h264 --output /tmp/x.bin`
     (passive; H.265 flows through the sink named "h264"; delete the dump after).
3. **Mismatch-heal check (the actual point of issue 10)** — with operator OK, flip the
   config key to 0 via ssh (`config.json` edit is what GL clients do) or set
   `set_params video_format=0` via the diag tunnel… simplest honest test: kill nothing,
   just set the persisted key to 0, have the operator disconnect/reconnect in Overlook,
   and watch the pin flip the encoder back to 1 before the watch. Restore/leave per
   guardrails (leave-as-set at 1 is the expected end state; tell the operator what
   changed).
4. **Tickets 04–08**: complete the live checkboxes (04 bump sanity live, 05 live e2e,
   06 fallback/watchdog — the deliberate-mismatch run in step 3 doubles as fallback
   evidence if you also test with the pin unavailable, e.g. wrong-auth client; use
   judgment, don't over-engineer, 07 preference UI live flips, 08 acceptance parity).
   Mark `done` / flip `ready-for-human` labels per `docs/agents/issue-tracker.md`.
5. **Strip instrumentation**: grep `DEBUG-h265` (app + tests; the tag was added in
   `cb36037`, but do NOT blind-revert — later commits build on those files). KEEP the
   permanent `[Overlook] encoder format pin…` logs and the env-gated
   `H265LiveWireDiagnosticTests` + `.scratch/h265-receive/tools/rtp_trace.py` (they're
   assets, not debris). Rebuild, run the suite (23 green + 2 env-skips expected),
   reinstall per the recipe below, operator smoke-checks once.
6. **Close out**: update tracker + handoff, one summary message to BDA over intercom
   (session name `subagent-chat-019ff2d0-f9dc-76da`, cwd BraindumpAssistant) for LAB-28
   mirroring. They're standing by and know the plan.

## Recipes (all proven this session)

- **Rebuild + reinstall** (after every rebuild that lands in /Applications):
  `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Release -derivedDataPath /tmp/overlook-build -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build`
  → `rm -rf /Applications/Overlook.app && ditto /tmp/overlook-build/Build/Products/Release/Overlook.app /Applications/Overlook.app`
  (rm first — ditto merges!) → `plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads":true}' /Applications/Overlook.app/Contents/Info.plist`
  → `codesign --force -s - …/Frameworks/WebRTC.framework` → `codesign --force -s - /Applications/Overlook.app`.
- **Tests**: same xcodebuild with `-configuration Debug -derivedDataPath /tmp/overlook-tests test`.
  The two live diagnostics skip unless env `TEST_RUNNER_OVERLOOK_H265_WIRE_DIAG=1` is set
  **in xcodebuild's environment** (as a CLI build-setting arg it does NOT reach the test
  process). Test NSLog output lands in the unified log
  (`log show --predicate 'process == "xctest"'`), not xcodebuild stdout.
- **Auth-free Janus access for the diagnostics**: `ssh -N -L 8080:/run/kvmd/janus-ws.sock root@100.92.27.77`
  (port 8080 ⇒ Overlook's URL normalization picks `ws://`; `/janus/ws` path accepted).
  For the RTP tracer use port 8188 + `/tmp/h265-trace-venv` (venv:
  `uv venv --python /opt/homebrew/bin/python3 --system-site-packages` + `uv pip install websockets`;
  needs brew `gstreamer`, `pygobject3`, `libnice-gstreamer` — all installed).
  Diagnostics need an encoder running: kvmd starts one only for authenticated kvmd
  clients (a bare Janus watch does NOT); the manual-encoder recipe is in the device
  access doc + `git show bb4abc9` (run-encoder script, self-killing, exact kvmd args).

## Gotchas (inherited + new this session)

- pi-lens clangd shows false-positive ObjC errors (WebRTC headers not in its include
  path) — xcodebuild is the authority. tree-sitter/module_report fails on this Swift.
- pbxproj object IDs are hand-allocated sequential hex — CHECK for collisions before
  adding (next free: BuildFile `01000042`, FileRef `02000038`).
- Test target compiles app sources directly (no @testable, no TEST_HOST) — internal is
  visible to tests; WebRTCManager + 6 deps are now in the test target too.
- kvmd rate-limits logins: 10 attempts/600 s, 600 s lockout. Stale tokens (from kvmd
  restarts) force a password re-prompt in Overlook — expected, not a bug.
- Device guardrails: production tool on the operator's work Mac. Reads/logs/dumps fine;
  no reboots/firmware; kvmd restart interrupts his input (~15 s) — check
  `stream.clients` or ask first. Leave codec state as found or say what changed.
- `-999 cancelled` on rapid set_params from the settings panel: parked, pre-existing.
- Two pre-existing Release warnings (`ContentView.swift`, `CoreAudioDevices.swift`) — upstream, leave.

## Coordination

- **Single-session rule (operator request)**: don't make him juggle sessions. You do
  device observation directly; BDA (intercom `subagent-chat-019ff2d0-f9dc-76da`) is
  message-only for LAB-28/LAB-29 mirroring. They expect a ping at verify-pass start and
  a summary at close; both are courtesy, not gates.
- Child-agent tooling note: workers on cortex-responses/openai-gpt-5.6-sol did tickets
  well; `anthropic/claude-fable-5` for hard adversarial review.
