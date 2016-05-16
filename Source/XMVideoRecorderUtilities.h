//
//  XMVideoRecorderUtilities.h
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/29.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface XMVideoRecorderUtilities : NSObject

+ (AVCaptureDevice *)captureDeviceForPosition:(AVCaptureDevicePosition)position;
+ (uint64_t)availableDiskSpaceInBytes;
+ (CMSampleBufferRef)createOffsetSampleBufferWithSampleBuffer:(CMSampleBufferRef)sampleBuffer withTimeOffset:(CMTime)timeOffset;
+ (NSString*)GetVideoLengthStringFromSeconds:(Float64)iVideoSeconds;
@end

@interface NSString (XMExtras)

+ (NSString *)XMformattedTimestampStringFromDate:(NSDate *)date;

@end
