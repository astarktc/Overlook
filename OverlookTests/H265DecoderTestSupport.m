#import "OverlookTests-Bridging-Header.h"

// Calls the RTCVideoDecoder protocol selector from Objective-C because Swift
// intentionally hides methods in the release method family.
NSInteger OverlookReleaseDecoder(RTCVideoDecoderH265 *decoder) {
    return [decoder releaseDecoder];
}
