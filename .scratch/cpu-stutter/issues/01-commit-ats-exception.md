# 01 — Commit the ATS exception so repo builds can connect

**What to build:** Any build produced from this repo can complete the kvmd auth login and stream from a Comet with its self-signed `glkvm` certificate, exactly like the currently installed app. Today repo builds fail with TLS -9802 because the ATS exception (`NSAppTransportSecurity → NSAllowsArbitraryLoads = true`) exists only in the out-of-band installed build's Info.plist, not in the project.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `NSAllowsArbitraryLoads = true` is set via the project (generated Info.plist / `INFOPLIST_KEY_NSAppTransportSecurity` or an Info.plist file), for all configurations
- [ ] A fresh `xcodebuild` product's Info.plist contains the key (verified with `plutil -p`)
- [ ] Decision recorded: blanket arbitrary loads chosen deliberately (Tailscale 100.x CGNAT addresses are not covered by `NSAllowsLocalNetworking`)
