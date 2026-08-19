import CoreGraphics
let did = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(did, opts) as? [CGDisplayMode] else { exit(1) }
guard let target = modes.first(where: {
    $0.width == 2560 && $0.height == 1440 && Int($0.refreshRate) == 60
        && $0.pixelWidth == 5120 && $0.isUsableForDesktopGUI()
}) else {
    print("target mode not found"); exit(1)
}
var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else { exit(2) }
CGConfigureDisplayWithDisplayMode(config, did, target, nil)
let err = CGCompleteDisplayConfiguration(config, .permanently)
print(err == .success
    ? "switched to 2560x1440 HiDPI (5120x2880 framebuffer), saved permanently"
    : "failed: \(err.rawValue)")
