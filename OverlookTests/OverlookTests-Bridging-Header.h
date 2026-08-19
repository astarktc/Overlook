#import <Foundation/Foundation.h>

// Swift cannot import Objective-C methods in the release method family, so
// this function keeps tests on the RTCVideoDecoder selector without adding a
// production-only API.
#import "../Overlook/OverlookVideoDecoderFactory.h"
#import "../Overlook/RTCVideoDecoderH265.h"
#import "../Overlook/RTCAudioDeviceShim.h"
#import "../Overlook/WebRTCFactoryBuilder.h"

NSInteger OverlookReleaseDecoder(RTCVideoDecoderH265 *decoder);
