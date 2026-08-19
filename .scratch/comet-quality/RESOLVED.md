# Comet quality / HiDPI thread — RESOLVED 2026-08-19

- CBR persistence deployed on device: `/etc/init.d/S97vencquality` (+ hook in S98kvmd `start()`).
  Still to verify once: survives next natural reboot.
- HiDPI goal achieved via override plist + **BetterDisplay** on the work Mac:
  HiDPI 1920×1080 (renders 3840×2160), mirrored, wire stays 1440p60. Verified via
  system_profiler and by Alex (fonts bigger, Overlook reports 1440p).
- EDID reflash path (option A) abandoned — LT6911C EDID flash region is effectively
  write-once via `-e`. See docs/agents/comet-device-access.md § HiDPI.
- Full evidence: docs/research/2026-08-18-comet-hidpi-4k60-bitrate.md
