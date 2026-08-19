// Copyright 2026 Overlook contributors.
//
// The decoder contract and VideoToolbox lifecycle are ported from
// HackWebRTC/webrtc's sdk/objc/components/video_codec/RTCVideoDecoderH265.mm
// (commit 7abfc990c00ab35090fff285fcf635d1d7892433), cross-referenced against
// WebKit's libwebrtc VideoToolbox H.265 decoder behavior.

#import <Foundation/Foundation.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoDecoder.h>

NS_ASSUME_NONNULL_BEGIN

/// The H.265 decoder's output buffer: behaviorally identical to `RTCCVPixelBuffer` — the class
/// itself is the frame's provenance.
///
/// After a codec fallback (always H.265 → H.264, and never back within a connection; see
/// `CodecSelectionPolicy`) the render path must refuse frames decoded from the abandoned H.265
/// stream no matter how late their decode callbacks run. A render-epoch token read at callback
/// start cannot do that — a callback that *begins* after the fallback reads the new token — so
/// the identity has to travel with the frame. This class is that identity. It reaches
/// `VideoRenderView.renderFrame` intact because WebRTC hands renderers the decoder's own buffer
/// instance (the same property the zero-copy display path already depends on).
@interface OverlookH265PixelBuffer : RTCCVPixelBuffer
@end

/// Hardware-only VideoToolbox H.265 decoder accepting Annex-B access units.
@interface RTCVideoDecoderH265 : NSObject <RTCVideoDecoder>
@end

NS_ASSUME_NONNULL_END
