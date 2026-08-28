#!/bin/bash
# HiDPI override installer — run ON THE WORK MAC (the Mac plugged into the Comet).
# Adds Retina "looks like" scaled modes for the Comet's virtual display (ViewSonic
# VX2478-2 identity, vendor 0x5a63 / product 0x2f34, native 2560x1440@60).
#
# DisplayProductName deliberately matches the wire EDID ("VX2478-2") so every
# surface (EDID, override, system_profiler, MDM inventory) shows one consistent,
# ordinary-monitor identity. Do NOT put "KVM" or "Comet" in this name — the
# override name is what MDM hardware inventory reports (renamed 2026-08-28).
# Wire stays 2560x1440@60; macOS renders a 2x framebuffer and downscales (smoother
# text/UI — supersampling, not true Retina detail).
#
# Usage:  sudo bash install-hidpi-override-on-work-mac.sh    (then reboot)
# Remove: sudo rm -r "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5a63" && reboot
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

DIR="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5a63"
mkdir -p "$DIR"
cat > "$DIR/DisplayProductID-2f34" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DisplayProductName</key>
	<string>VX2478-2</string>
	<key>DisplayProductID</key>
	<integer>12084</integer>
	<key>DisplayVendorID</key>
	<integer>23139</integer>
	<key>scale-resolutions</key>
	<array>
		<data>AAAUAAAAC0AAAAAB</data>
		<data>AAAQAAAACQAAAAAB</data>
		<data>AAAPAAAACHAAAAAB</data>
		<data>AAAMgAAABwgAAAAB</data>
	</array>
</dict>
</plist>
PLIST
plutil -lint "$DIR/DisplayProductID-2f34"
echo "Installed. Reboot, then System Settings > Displays should offer scaled"
echo "'looks like' options (2560x1440 / 2048x1152 / 1920x1080 / 1600x900, all @2x)."
