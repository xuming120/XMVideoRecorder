//
//  XMVideoRecorderUtilities.m
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/29.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import "XMVideoRecorderUtilities.h"
#import "XMVideoRecorder.h"
#import <OpenGLES/EAGL.h>

@implementation XMVideoRecorderUtilities

+ (AVCaptureDevice *)captureDeviceForPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if ([device position] == position) {
            return device;
        }
    }
    
    return nil;
}

+ (uint64_t)availableDiskSpaceInBytes
{
    uint64_t totalFreeSpace = 0;
    
    __autoreleasing NSError *error = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[paths lastObject] error:&error];
    
    if (dictionary) {
        NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];
        totalFreeSpace = [freeFileSystemSizeInBytes unsignedLongLongValue];
    }
    
    return totalFreeSpace;
}

+ (CMSampleBufferRef)createOffsetSampleBufferWithSampleBuffer:(CMSampleBufferRef)sampleBuffer withTimeOffset:(CMTime)timeOffset
{
    CMItemCount itemCount;
    
    OSStatus status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, NULL, &itemCount);
    if (status) {
        return NULL;
    }
    
    CMSampleTimingInfo *timingInfo = (CMSampleTimingInfo *)malloc(sizeof(CMSampleTimingInfo) * (unsigned long)itemCount);
    if (!timingInfo) {
        return NULL;
    }
    
    status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, itemCount, timingInfo, &itemCount);
    if (status) {
        free(timingInfo);
        timingInfo = NULL;
        return NULL;
    }
    
    for (CMItemCount i = 0; i < itemCount; i++) {
        timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, timeOffset);
        timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, timeOffset);
    }
    
    CMSampleBufferRef offsetSampleBuffer;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, itemCount, timingInfo, &offsetSampleBuffer);
    
    if (timingInfo) {
        free(timingInfo);
        timingInfo = NULL;
    }
    
    return offsetSampleBuffer;
}

+ (NSString*)GetVideoLengthStringFromSeconds:(Float64)iVideoSeconds
{
    int iSecond = 0;
    int iMinute = 0;
    int iHour = 0;
    NSString *strRet = nil;
    
    //计算小时
    iHour = (UInt32)(iVideoSeconds/3600);
    iHour = MIN(iHour, 59);
    
    //计算分钟
    iMinute = (UInt32)(iVideoSeconds/60);
    if(iMinute>60) iMinute = iMinute % 60;
    iMinute = MIN(iMinute, 59);
    
    //计算秒数
    iSecond = ((UInt32)iVideoSeconds) % 60;
    iSecond = MIN(iSecond, 59);
    
    //显示时间格式
//    if(iHour==0)
//        strRet = [NSString stringWithFormat:@"%02i:%02i",iMinute,iSecond];
//    else
        strRet = [NSString stringWithFormat:@"%02i:%02i:%02i",iHour,iMinute,iSecond];
    return strRet;
}


@end

#pragma mark - NSString Extras

@implementation NSString (XMExtras)

+ (NSString *)XMformattedTimestampStringFromDate:(NSDate *)date
{
    if (!date)
        return nil;
    
    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'SSS'Z'"];
        [dateFormatter setLocale:[NSLocale autoupdatingCurrentLocale]];
    });
    
    return [dateFormatter stringFromDate:date];
}
@end
