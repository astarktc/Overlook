// Copyright 2026 Overlook contributors.
//
// Ported from HackWebRTC/webrtc RTCVideoDecoderH265.mm at
// 7abfc990c00ab35090fff285fcf635d1d7892433, with parameter-set reconfiguration
// and hardware-only session creation added for Overlook's receive-only use.

#import "RTCVideoDecoderH265.h"

#import "H265NaluParser.h"

#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <WebRTC/RTCCVPixelBuffer.h>

static NSInteger const H265VideoCodecOK = 0;
static NSInteger const H265VideoCodecError = -1;

@implementation OverlookH265PixelBuffer
@end

@class RTCVideoDecoderH265;

@interface H265DecodeContext : NSObject
@property(nonatomic, strong) RTCVideoDecoderH265 *decoder;
@property(nonatomic, copy) RTCVideoDecoderCallback callback;
@property(nonatomic) uint32_t timestamp;
@property(nonatomic) NSUInteger reorderSize;
@end

@implementation H265DecodeContext
@end

@interface H265QueuedFrame : NSObject
@property(nonatomic, strong) RTCVideoFrame *frame;
@property(nonatomic, copy) RTCVideoDecoderCallback callback;
@property(nonatomic) uint32_t timestamp;
@property(nonatomic) NSUInteger reorderSize;
@end

@implementation H265QueuedFrame
@end

@interface RTCVideoDecoderH265 ()
- (void)processDecodedFrame:(RTCVideoFrame *)frame context:(H265DecodeContext *)context;
@end

static void H265DecompressionOutputCallback(
    void *decompressionOutputRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration) {
    (void)decompressionOutputRefCon;
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;

    H265DecodeContext *context = CFBridgingRelease(sourceFrameRefCon);
    if (status != noErr || imageBuffer == NULL) {
        NSLog(@"RTCVideoDecoderH265: VideoToolbox decode failed (%d)", (int)status);
        return;
    }

    // The marker subclass, not RTCCVPixelBuffer: the buffer instance travels to the renderer
    // as-is, so its class carries H.265 provenance for the codec-fallback admission guard.
    OverlookH265PixelBuffer *frameBuffer =
        [[OverlookH265PixelBuffer alloc] initWithPixelBuffer:imageBuffer];
    int64_t timeStampNs = (int64_t)((double)context.timestamp * (1000000000.0 / 90000.0));
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:frameBuffer
                                                        rotation:RTCVideoRotation_0
                                                     timeStampNs:timeStampNs];
    frame.timeStamp = (int32_t)context.timestamp;
    [context.decoder processDecodedFrame:frame context:context];
}

@implementation RTCVideoDecoderH265 {
    CMVideoFormatDescriptionRef _videoFormat;
    VTDecompressionSessionRef _decompressionSession;
    RTCVideoDecoderCallback _callback;

    NSData *_currentVPS;
    NSData *_currentSPS;
    NSData *_currentPPS;
    NSUInteger _reorderSize;

    NSLock *_outputLock;
    NSMutableArray<H265QueuedFrame *> *_reorderQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _outputLock = [[NSLock alloc] init];
        _reorderQueue = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self destroyDecompressionSessionFlushingFrames:YES];
    if (_videoFormat != NULL) {
        CFRelease(_videoFormat);
    }
}

- (void)setCallback:(RTCVideoDecoderCallback)callback {
    _callback = [callback copy];
}

- (NSInteger)startDecodeWithNumberOfCores:(int)numberOfCores {
    (void)numberOfCores;
    return H265VideoCodecOK;
}

- (NSInteger)decode:(RTCEncodedImage *)inputImage
          missingFrames:(BOOL)missingFrames
      codecSpecificInfo:(id<RTCCodecSpecificInfo>)info
           renderTimeMs:(int64_t)renderTimeMs {
    (void)missingFrames;
    (void)info;
    (void)renderTimeMs;

    if (inputImage.buffer.length == 0 || _callback == nil) {
        return H265VideoCodecError;
    }

    NSArray<H265NaluUnit *> *nalus = H265ParseAnnexBAccessUnit(inputImage.buffer);
    NSData *incomingVPS = nil;
    NSData *incomingSPS = nil;
    NSData *incomingPPS = nil;
    for (H265NaluUnit *nalu in nalus) {
        switch (nalu.type) {
            case 32:
                incomingVPS = nalu.data;
                break;
            case 33:
                incomingSPS = nalu.data;
                break;
            case 34:
                incomingPPS = nalu.data;
                break;
            default:
                break;
        }
    }

    NSData *candidateVPS = incomingVPS ?: _currentVPS;
    NSData *candidateSPS = incomingSPS ?: _currentSPS;
    NSData *candidatePPS = incomingPPS ?: _currentPPS;
    BOOL parameterSetsChanged =
        (incomingVPS != nil && ![incomingVPS isEqualToData:_currentVPS]) ||
        (incomingSPS != nil && ![incomingSPS isEqualToData:_currentSPS]) ||
        (incomingPPS != nil && ![incomingPPS isEqualToData:_currentPPS]);

    if (candidateVPS != nil && candidateSPS != nil && candidatePPS != nil &&
        (_videoFormat == NULL || parameterSetsChanged)) {
        if (![self updateVideoFormatWithVPS:candidateVPS SPS:candidateSPS PPS:candidatePPS]) {
            return H265VideoCodecError;
        }
    }

    if (_videoFormat == NULL || _decompressionSession == NULL) {
        NSLog(@"RTCVideoDecoderH265: waiting for in-band VPS/SPS/PPS");
        return H265VideoCodecError;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    if (!H265CreateSampleBufferFromAnnexB(inputImage.buffer, _videoFormat, &sampleBuffer)) {
        return H265VideoCodecError;
    }

    H265DecodeContext *context = [[H265DecodeContext alloc] init];
    context.decoder = self;
    context.callback = _callback;
    context.timestamp = inputImage.timeStamp;
    context.reorderSize = _reorderSize;
    void *sourceFrameRefCon = (__bridge_retained void *)context;
    OSStatus status = VTDecompressionSessionDecodeFrame(
        _decompressionSession,
        sampleBuffer,
        kVTDecodeFrame_EnableAsynchronousDecompression,
        sourceFrameRefCon,
        NULL);
    CFRelease(sampleBuffer);
    if (status != noErr) {
        CFBridgingRelease(sourceFrameRefCon);
        NSLog(@"RTCVideoDecoderH265: failed to submit frame (%d)", (int)status);
        return H265VideoCodecError;
    }
    return H265VideoCodecOK;
}

- (NSInteger)releaseDecoder {
    [self destroyDecompressionSessionFlushingFrames:YES];
    _callback = nil;
    _currentVPS = nil;
    _currentSPS = nil;
    _currentPPS = nil;
    _reorderSize = 0;
    if (_videoFormat != NULL) {
        CFRelease(_videoFormat);
        _videoFormat = NULL;
    }
    return H265VideoCodecOK;
}

- (NSString *)implementationName {
    return @"VideoToolbox-H265-Hardware";
}

#pragma mark - Parameter sets and session lifecycle

- (BOOL)updateVideoFormatWithVPS:(NSData *)vps SPS:(NSData *)sps PPS:(NSData *)pps {
    const uint8_t *parameterSetPointers[3] = {vps.bytes, sps.bytes, pps.bytes};
    const size_t parameterSetSizes[3] = {vps.length, sps.length, pps.length};
    CMVideoFormatDescriptionRef newFormat = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault,
        3,
        parameterSetPointers,
        parameterSetSizes,
        4,
        NULL,
        &newFormat);
    if (status != noErr || newFormat == NULL) {
        NSLog(@"RTCVideoDecoderH265: invalid VPS/SPS/PPS (%d)", (int)status);
        return NO;
    }

    [self destroyDecompressionSessionFlushingFrames:YES];
    if (_videoFormat != NULL) {
        CFRelease(_videoFormat);
    }
    _videoFormat = newFormat;
    _currentVPS = [vps copy];
    _currentSPS = [sps copy];
    _currentPPS = [pps copy];
    _reorderSize = H265MaxNumReorderPicsFromVPS(vps);

    if (![self createHardwareDecompressionSession]) {
        CFRelease(_videoFormat);
        _videoFormat = NULL;
        return NO;
    }
    return YES;
}

- (BOOL)createHardwareDecompressionSession {
    NSDictionary *decoderSpecification = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES,
    };
    NSDictionary *destinationAttributes = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    };
    VTDecompressionOutputCallbackRecord callbackRecord = {
        .decompressionOutputCallback = H265DecompressionOutputCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _videoFormat,
        (__bridge CFDictionaryRef)decoderSpecification,
        (__bridge CFDictionaryRef)destinationAttributes,
        &callbackRecord,
        &_decompressionSession);
    if (status != noErr || _decompressionSession == NULL) {
        _decompressionSession = NULL;
        NSLog(@"RTCVideoDecoderH265: hardware decoder unavailable (%d)", (int)status);
        return NO;
    }

    CFTypeRef hardwareDecoder = NULL;
    status = VTSessionCopyProperty(
        _decompressionSession,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        kCFAllocatorDefault,
        &hardwareDecoder);
    BOOL usingHardware = status == noErr && hardwareDecoder != NULL &&
                         CFEqual(hardwareDecoder, kCFBooleanTrue);
    if (hardwareDecoder != NULL) {
        CFRelease(hardwareDecoder);
    }
    if (!usingHardware) {
        NSLog(@"RTCVideoDecoderH265: refusing non-hardware decoder session");
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
        return NO;
    }

    (void)VTSessionSetProperty(
        _decompressionSession,
        kVTDecompressionPropertyKey_RealTime,
        kCFBooleanTrue);
    return YES;
}

- (void)destroyDecompressionSessionFlushingFrames:(BOOL)flushFrames {
    if (_decompressionSession != NULL) {
        if (flushFrames) {
            (void)VTDecompressionSessionFinishDelayedFrames(_decompressionSession);
        }
        (void)VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
    if (flushFrames) {
        [self flushReorderQueue];
    }
}

#pragma mark - Output ordering

- (void)processDecodedFrame:(RTCVideoFrame *)frame context:(H265DecodeContext *)context {
    H265QueuedFrame *queuedFrame = [[H265QueuedFrame alloc] init];
    queuedFrame.frame = frame;
    queuedFrame.callback = context.callback;
    queuedFrame.timestamp = context.timestamp;
    queuedFrame.reorderSize = context.reorderSize;

    NSMutableArray<H265QueuedFrame *> *readyFrames = [NSMutableArray array];
    [_outputLock lock];
    [_reorderQueue addObject:queuedFrame];
    [_reorderQueue sortUsingComparator:^NSComparisonResult(H265QueuedFrame *left,
                                                            H265QueuedFrame *right) {
        if (left.timestamp < right.timestamp) {
            return NSOrderedAscending;
        }
        if (left.timestamp > right.timestamp) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    while (_reorderQueue.count > 0 &&
           _reorderQueue.count > _reorderQueue.firstObject.reorderSize) {
        [readyFrames addObject:_reorderQueue.firstObject];
        [_reorderQueue removeObjectAtIndex:0];
    }
    [_outputLock unlock];

    for (H265QueuedFrame *readyFrame in readyFrames) {
        readyFrame.callback(readyFrame.frame);
    }
}

- (void)flushReorderQueue {
    NSArray<H265QueuedFrame *> *frames = nil;
    [_outputLock lock];
    frames = [_reorderQueue copy];
    [_reorderQueue removeAllObjects];
    [_outputLock unlock];

    for (H265QueuedFrame *frame in frames) {
        frame.callback(frame.frame);
    }
}

@end
