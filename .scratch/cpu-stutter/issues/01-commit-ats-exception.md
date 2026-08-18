# 01 — Commit the ATS exception so repo builds can connect

**What to build:** Any build produced from this repo can complete the kvmd auth login and stream from a Comet with its self-signed `glkvm` certificate, exactly like the currently installed app. Today repo builds fail with TLS -9802 because the ATS exception (`NSAppTransportSecurity → NSAllowsArbitraryLoads = true`) exists only in the out-of-band installed build's Info.plist, not in the project.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] `NSAllowsArbitraryLoads = true` is set via the project (generated Info.plist / `INFOPLIST_KEY_NSAppTransportSecurity` or an Info.plist file), for all configurations
- [x] A fresh `xcodebuild` product's Info.plist contains the key (verified with `plutil -p`)
- [x] Decision recorded: blanket arbitrary loads chosen deliberately (Tailscale 100.x CGNAT addresses are not covered by `NSAllowsLocalNetworking`)

## Resolution

`INFOPLIST_KEY_*` cannot express a dictionary, so the exception lives in a partial
`Overlook/Info.plist` containing only `NSAppTransportSecurity → NSAllowsArbitraryLoads = true`,
wired up with `INFOPLIST_FILE = Overlook/Info.plist` in both app-target build configurations
(Debug `12000003` and Release `12000004`). `GENERATE_INFOPLIST_FILE` stays `YES`, and Xcode
merges its generated keys into the partial file — verified in the built product:

```text
$ plutil -p build/ticket01/Build/Products/Debug/Overlook.app/Contents/Info.plist | grep -A3 Transport
  "NSAppTransportSecurity" => {
    "NSAllowsArbitraryLoads" => true
  }
  "NSMicrophoneUsageDescription" => "Overlook needs microphone access to send audio to the remote device."
```

`LSMinimumSystemVersion => 14.0`, `NSAccentColorName`, and the CFBundle* identity keys are all
still generated (no regression). Negative control: the same build with `INFOPLIST_FILE=""`
produces no ATS key, confirming the new file is the source of the setting.

Rationale for the blanket exception is documented as an XML comment inside `Overlook/Info.plist`.
