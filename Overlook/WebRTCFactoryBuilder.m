#import "WebRTCFactoryBuilder.h"

#import "OverlookVideoDecoderFactory.h"

@implementation WebRTCFactoryBuilder

+ (RTCPeerConnectionFactory *)makeFactoryWithAudioDevice:(id<RTCAudioDevice>)audioDevice {
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    OverlookVideoDecoderFactory *decoderFactory = [[OverlookVideoDecoderFactory alloc] init];

    if (audioDevice != nil) {
        return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                         decoderFactory:decoderFactory
                                                            audioDevice:audioDevice];
    }

    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                     decoderFactory:decoderFactory];
}

+ (void)setPlayoutDelayHintIfSupportedForReceiver:(RTCRtpReceiver *)receiver seconds:(double)seconds {
    if (receiver == nil) {
        return;
    }

    SEL sel = NSSelectorFromString(@"setPlayoutDelayHint:");
    if (![receiver respondsToSelector:sel]) {
        return;
    }

    NSMethodSignature *sig = [receiver methodSignatureForSelector:sel];
    if (sig == nil) {
        return;
    }

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:receiver];
    [inv setSelector:sel];

    double value = seconds;
    [inv setArgument:&value atIndex:2];
    [inv invoke];
}

@end
