// Copyright 2026 Overlook contributors.

#import "OverlookVideoDecoderFactory.h"

#import "RTCVideoDecoderH265.h"

@implementation OverlookVideoDecoderFactory {
    RTCDefaultVideoDecoderFactory *_defaultFactory;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaultFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    }
    return self;
}

- (NSArray<RTCVideoCodecInfo *> *)supportedCodecs {
    NSMutableArray<RTCVideoCodecInfo *> *codecs = [[_defaultFactory supportedCodecs] mutableCopy];
    BOOL alreadyAdvertised = NO;
    for (RTCVideoCodecInfo *codec in codecs) {
        if ([codec.name caseInsensitiveCompare:@"H265"] == NSOrderedSame &&
            [codec.parameters[@"profile-id"] isEqualToString:@"1"]) {
            alreadyAdvertised = YES;
            break;
        }
    }
    if (!alreadyAdvertised) {
        [codecs addObject:[[RTCVideoCodecInfo alloc] initWithName:@"H265"
                                                      parameters:@{@"profile-id": @"1"}]];
    }
    return codecs;
}

- (id<RTCVideoDecoder>)createDecoder:(RTCVideoCodecInfo *)info {
    if ([info.name caseInsensitiveCompare:@"H265"] == NSOrderedSame) {
        NSString *profileID = info.parameters[@"profile-id"];
        if (profileID == nil || [profileID isEqualToString:@"1"]) {
            return [[RTCVideoDecoderH265 alloc] init];
        }
        return nil;
    }
    return [_defaultFactory createDecoder:info];
}

@end
