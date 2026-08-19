// Copyright 2026 Overlook contributors.
//
// Annex-B parsing and VideoToolbox sample conversion are adapted from
// HackWebRTC/webrtc's sdk/objc/components/video_codec/nalu_rewriter.cc
// (commit 7abfc990c00ab35090fff285fcf635d1d7892433).

#import "H265NaluParser.h"

#import <CoreFoundation/CoreFoundation.h>

@interface H265NaluUnit ()
@property(nonatomic, readwrite) NSData *data;
@property(nonatomic, readwrite) uint8_t type;
@end

@implementation H265NaluUnit

- (instancetype)initWithData:(NSData *)data type:(uint8_t)type {
    self = [super init];
    if (self) {
        _data = data;
        _type = type;
    }
    return self;
}

@end

static NSUInteger H265StartCodeLength(const uint8_t *bytes, NSUInteger length, NSUInteger offset) {
    if (offset + 3 <= length && bytes[offset] == 0 && bytes[offset + 1] == 0 &&
        bytes[offset + 2] == 1) {
        return 3;
    }
    if (offset + 4 <= length && bytes[offset] == 0 && bytes[offset + 1] == 0 &&
        bytes[offset + 2] == 0 && bytes[offset + 3] == 1) {
        return 4;
    }
    return 0;
}

NSArray<H265NaluUnit *> *H265ParseAnnexBAccessUnit(NSData *accessUnit) {
    const uint8_t *bytes = accessUnit.bytes;
    const NSUInteger length = accessUnit.length;
    NSMutableArray<NSNumber *> *startOffsets = [NSMutableArray array];
    NSMutableArray<NSNumber *> *startCodeLengths = [NSMutableArray array];

    NSUInteger offset = 0;
    while (offset + 3 <= length) {
        NSUInteger startCodeLength = H265StartCodeLength(bytes, length, offset);
        if (startCodeLength != 0) {
            [startOffsets addObject:@(offset)];
            [startCodeLengths addObject:@(startCodeLength)];
            offset += startCodeLength;
        } else {
            offset += 1;
        }
    }

    NSMutableArray<H265NaluUnit *> *nalus = [NSMutableArray arrayWithCapacity:startOffsets.count];
    for (NSUInteger index = 0; index < startOffsets.count; ++index) {
        NSUInteger payloadStart = startOffsets[index].unsignedIntegerValue +
                                  startCodeLengths[index].unsignedIntegerValue;
        NSUInteger payloadEnd = index + 1 < startOffsets.count
                                    ? startOffsets[index + 1].unsignedIntegerValue
                                    : length;
        while (payloadEnd > payloadStart && bytes[payloadEnd - 1] == 0) {
            // Annex-B trailing_zero_8bits are not part of the NAL unit.
            payloadEnd -= 1;
        }
        if (payloadEnd <= payloadStart) {
            continue;
        }

        NSData *data = [accessUnit subdataWithRange:NSMakeRange(payloadStart, payloadEnd - payloadStart)];
        uint8_t type = (bytes[payloadStart] >> 1) & 0x3f;
        [nalus addObject:[[H265NaluUnit alloc] initWithData:data type:type]];
    }
    return nalus;
}

typedef struct {
    const uint8_t *bytes;
    NSUInteger byteCount;
    NSUInteger bitOffset;
    BOOL valid;
} H265BitReader;

static uint32_t H265ReadBits(H265BitReader *reader, NSUInteger count) {
    if (!reader->valid || count > 32 || reader->bitOffset + count > reader->byteCount * 8) {
        reader->valid = NO;
        return 0;
    }
    uint32_t result = 0;
    for (NSUInteger index = 0; index < count; ++index) {
        NSUInteger bit = reader->bitOffset + index;
        result = (result << 1) | ((reader->bytes[bit / 8] >> (7 - bit % 8)) & 1);
    }
    reader->bitOffset += count;
    return result;
}

static BOOL H265SkipBits(H265BitReader *reader, NSUInteger count) {
    while (count > 0 && reader->valid) {
        NSUInteger chunk = MIN(count, (NSUInteger)32);
        (void)H265ReadBits(reader, chunk);
        count -= chunk;
    }
    return reader->valid;
}

static uint32_t H265ReadUnsignedExpGolomb(H265BitReader *reader) {
    NSUInteger leadingZeros = 0;
    while (reader->valid && H265ReadBits(reader, 1) == 0) {
        leadingZeros += 1;
        if (leadingZeros > 31) {
            reader->valid = NO;
            return 0;
        }
    }
    if (!reader->valid || leadingZeros == 0) {
        return 0;
    }
    uint32_t suffix = H265ReadBits(reader, leadingZeros);
    if (!reader->valid) {
        return 0;
    }
    return ((uint32_t)1 << leadingZeros) - 1 + suffix;
}

static BOOL H265SkipProfileTierLevel(H265BitReader *reader, NSUInteger maxSubLayersMinusOne) {
    // general_profile_* through general_constraint_indicator_flags, then level_idc.
    (void)H265SkipBits(reader, 88);
    (void)H265SkipBits(reader, 8);

    BOOL profilePresent[7] = {NO};
    BOOL levelPresent[7] = {NO};
    for (NSUInteger index = 0; index < maxSubLayersMinusOne; ++index) {
        profilePresent[index] = H265ReadBits(reader, 1) != 0;
        levelPresent[index] = H265ReadBits(reader, 1) != 0;
    }
    if (maxSubLayersMinusOne > 0) {
        for (NSUInteger index = maxSubLayersMinusOne; index < 8; ++index) {
            (void)H265ReadBits(reader, 2);
        }
    }
    for (NSUInteger index = 0; index < maxSubLayersMinusOne; ++index) {
        if (profilePresent[index]) {
            (void)H265SkipBits(reader, 88);
        }
        if (levelPresent[index]) {
            (void)H265ReadBits(reader, 8);
        }
    }
    return reader->valid;
}

NSUInteger H265MaxNumReorderPicsFromVPS(NSData *vps) {
    if (vps.length <= 2) {
        return 0;
    }

    // Remove the two-byte NAL header and emulation-prevention bytes to obtain RBSP.
    const uint8_t *source = vps.bytes;
    NSMutableData *rbsp = [NSMutableData dataWithCapacity:vps.length - 2];
    NSUInteger zeroCount = 0;
    for (NSUInteger index = 2; index < vps.length; ++index) {
        uint8_t byte = source[index];
        if (zeroCount >= 2 && byte == 3) {
            zeroCount = 0;
            continue;
        }
        [rbsp appendBytes:&byte length:1];
        zeroCount = byte == 0 ? zeroCount + 1 : 0;
    }

    H265BitReader reader = {
        .bytes = rbsp.bytes,
        .byteCount = rbsp.length,
        .bitOffset = 0,
        .valid = YES,
    };
    (void)H265ReadBits(&reader, 4); // vps_video_parameter_set_id
    (void)H265ReadBits(&reader, 1); // vps_base_layer_internal_flag
    (void)H265ReadBits(&reader, 1); // vps_base_layer_available_flag
    (void)H265ReadBits(&reader, 6); // vps_max_layers_minus1
    NSUInteger maxSubLayersMinusOne = H265ReadBits(&reader, 3);
    (void)H265ReadBits(&reader, 1);  // vps_temporal_id_nesting_flag
    (void)H265ReadBits(&reader, 16); // vps_reserved_0xffff_16bits
    if (!reader.valid || maxSubLayersMinusOne >= 7 ||
        !H265SkipProfileTierLevel(&reader, maxSubLayersMinusOne)) {
        return 0;
    }

    BOOL orderingInfoPresent = H265ReadBits(&reader, 1) != 0;
    NSUInteger firstLayer = orderingInfoPresent ? 0 : maxSubLayersMinusOne;
    NSUInteger maximum = 0;
    for (NSUInteger layer = firstLayer; layer <= maxSubLayersMinusOne; ++layer) {
        (void)H265ReadUnsignedExpGolomb(&reader); // vps_max_dec_pic_buffering_minus1
        uint32_t reorderPics = H265ReadUnsignedExpGolomb(&reader);
        (void)H265ReadUnsignedExpGolomb(&reader); // vps_max_latency_increase_plus1
        maximum = MAX(maximum, (NSUInteger)reorderPics);
    }
    if (!reader.valid) {
        return 0;
    }

    // Port of shiguredo-webrtc-build's vps_max_num_reorder_pics fix
    // (patches/h265.patch at c0fba486c712cce45d32e5390b73934c53f0ce67).
    // Using a generic maximum reorder depth can hold many decoded frames before
    // the first callback; the VPS value prevents that long time-to-first-frame.
    return MIN(maximum, (NSUInteger)16);
}

BOOL H265CreateSampleBufferFromAnnexB(
    NSData *accessUnit,
    CMVideoFormatDescriptionRef videoFormat,
    CMSampleBufferRef *outSampleBuffer) {
    NSArray<H265NaluUnit *> *nalus = H265ParseAnnexBAccessUnit(accessUnit);
    NSMutableData *lengthPrefixedData = [NSMutableData dataWithCapacity:accessUnit.length];
    for (H265NaluUnit *nalu in nalus) {
        if (nalu.type == 32 || nalu.type == 33 || nalu.type == 34) {
            continue;
        }
        if (nalu.data.length > UINT32_MAX) {
            return NO;
        }
        uint32_t bigEndianLength = CFSwapInt32HostToBig((uint32_t)nalu.data.length);
        [lengthPrefixedData appendBytes:&bigEndianLength length:sizeof(bigEndianLength)];
        [lengthPrefixedData appendData:nalu.data];
    }
    if (lengthPrefixedData.length == 0) {
        return NO;
    }

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        NULL,
        lengthPrefixedData.length,
        kCFAllocatorDefault,
        NULL,
        0,
        lengthPrefixedData.length,
        kCMBlockBufferAssureMemoryNowFlag,
        &blockBuffer);
    if (status != kCMBlockBufferNoErr) {
        return NO;
    }
    status = CMBlockBufferReplaceDataBytes(
        lengthPrefixedData.bytes, blockBuffer, 0, lengthPrefixedData.length);
    if (status != kCMBlockBufferNoErr) {
        CFRelease(blockBuffer);
        return NO;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuffer,
        videoFormat,
        1,
        0,
        NULL,
        0,
        NULL,
        &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || sampleBuffer == NULL) {
        return NO;
    }
    *outSampleBuffer = sampleBuffer;
    return YES;
}
