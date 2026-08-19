// Copyright 2026 Overlook contributors.
//
// The decoder contract and VideoToolbox lifecycle are ported from
// HackWebRTC/webrtc's sdk/objc/components/video_codec/RTCVideoDecoderH265.mm
// (commit 7abfc990c00ab35090fff285fcf635d1d7892433), cross-referenced against
// WebKit's libwebrtc VideoToolbox H.265 decoder behavior.

#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoDecoder.h>

NS_ASSUME_NONNULL_BEGIN

/// Hardware-only VideoToolbox H.265 decoder accepting Annex-B access units.
@interface RTCVideoDecoderH265 : NSObject <RTCVideoDecoder>
@end

NS_ASSUME_NONNULL_END
