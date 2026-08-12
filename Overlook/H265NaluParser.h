// Copyright 2026 Overlook contributors.
//
// Annex-B parsing and VideoToolbox sample conversion are adapted from
// HackWebRTC/webrtc's sdk/objc/components/video_codec/nalu_rewriter.{h,cc}
// (commit 7abfc990c00ab35090fff285fcf635d1d7892433).

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface H265NaluUnit : NSObject

@property(nonatomic, readonly) NSData *data;
@property(nonatomic, readonly) uint8_t type;

- (instancetype)init NS_UNAVAILABLE;

@end

/// Returns the NAL units in an Annex-B access unit, without their start codes.
NSArray<H265NaluUnit *> *H265ParseAnnexBAccessUnit(NSData *accessUnit);

/// Reads max(vps_max_num_reorder_pics[]) from a VPS, clamped to 16.
NSUInteger H265MaxNumReorderPicsFromVPS(NSData *vps);

/// Converts the VCL/non-parameter-set NAL units to four-byte length-prefixed
/// form and creates a retained sample buffer using `videoFormat`.
// Clang cannot infer both pointer levels for a CoreFoundation typedef out-param.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
BOOL H265CreateSampleBufferFromAnnexB(
    NSData *accessUnit,
    CMVideoFormatDescriptionRef videoFormat,
    CMSampleBufferRef *outSampleBuffer);
#pragma clang diagnostic pop

NS_ASSUME_NONNULL_END
