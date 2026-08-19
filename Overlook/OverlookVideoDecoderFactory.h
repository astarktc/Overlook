// Copyright 2026 Overlook contributors.

#import <Foundation/Foundation.h>
#import <WebRTC/RTCDefaultVideoDecoderFactory.h>
#import <WebRTC/RTCVideoDecoderFactory.h>

NS_ASSUME_NONNULL_BEGIN

/// Adds Overlook's receive-only H.265 decoder to the SDK's default decoders.
@interface OverlookVideoDecoderFactory : NSObject <RTCVideoDecoderFactory>
@end

NS_ASSUME_NONNULL_END
