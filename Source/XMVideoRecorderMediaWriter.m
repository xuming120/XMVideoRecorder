//
//  XMVideoRecorderMediaWriter.m
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/29.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import "XMVideoRecorderMediaWriter.h"
#import <AVFoundation/AVFoundation.h>
#import "XMVideoRecorder.h"

#define LOG_WRITER 1
#if !defined(NDEBUG) && LOG_WRITER
#   define DLog(fmt, ...) NSLog((@"writer: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif

@interface XMVideoRecorderMediaWriter ()
{
    AVAssetWriter *_assetWriter;
    AVAssetWriterInput *_assetWriterAudioInput;
    AVAssetWriterInput *_assetWriterVideoInput;
}

@end

@implementation XMVideoRecorderMediaWriter

#pragma mark - getters/setters

- (BOOL)isAudioReady
{
    AVAuthorizationStatus audioAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    
    BOOL isAudioNotAuthorized = (audioAuthorizationStatus == AVAuthorizationStatusNotDetermined || audioAuthorizationStatus == AVAuthorizationStatusDenied);
    BOOL isAudioSetup = (_assetWriterAudioInput != nil) || isAudioNotAuthorized;
    
    return isAudioSetup;
}

- (BOOL)isVideoReady
{
    AVAuthorizationStatus videoAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    
    BOOL isVideoNotAuthorized = (videoAuthorizationStatus == AVAuthorizationStatusNotDetermined || videoAuthorizationStatus == AVAuthorizationStatusDenied);
    BOOL isVideoSetup = (_assetWriterVideoInput != nil) || isVideoNotAuthorized;
    
    return isVideoSetup;
}

- (NSError *)error
{
    return _assetWriter.error;
}

#pragma mark - init

- (id)initWithOutputURL:(NSURL *)outputURL
{
    self = [super init];
    if (self) {
        NSError *error = nil;
        _assetWriter = [AVAssetWriter assetWriterWithURL:outputURL fileType:AVFileTypeMPEG4 error:&error];
        if (error) {
            DLog(@"error setting up the asset writer (%@)", error);
            _assetWriter = nil;
            return nil;
        }
        _assetWriter.shouldOptimizeForNetworkUse = YES;
        
        _outputURL = outputURL;

        _audioTimestamp = kCMTimeInvalid;
        _videoTimestamp = kCMTimeInvalid;
        
        DLog(@"prepared to write to (%@)", outputURL);
    }
    return self;
}

#pragma mark - setup

- (BOOL)setupAudioWithSettings:(NSDictionary *)audioSettings
{
    if (!_assetWriterAudioInput && [_assetWriter canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]) {
        
        _assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        _assetWriterAudioInput.expectsMediaDataInRealTime = YES;
        
        if (_assetWriterAudioInput && [_assetWriter canAddInput:_assetWriterAudioInput]) {
            [_assetWriter addInput:_assetWriterAudioInput];
            
            DLog(@"setup audio input with settings sampleRate (%f) channels (%lu) bitRate (%ld)",
                 [[audioSettings objectForKey:AVSampleRateKey] floatValue],
                 (unsigned long)[[audioSettings objectForKey:AVNumberOfChannelsKey] unsignedIntegerValue],
                 (long)[[audioSettings objectForKey:AVEncoderBitRateKey] integerValue]);
            
        } else {
            DLog(@"couldn't add asset writer audio input");
        }
        
    } else {
        
        _assetWriterAudioInput = nil;
        DLog(@"couldn't apply audio output settings");
        
    }
    
    return self.isAudioReady;
}

- (BOOL)setupVideoWithSettings:(NSDictionary *)videoSettings withAdditional:(NSDictionary *)additional
{
    if (!_assetWriterVideoInput && [_assetWriter canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {
        
        _assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        _assetWriterVideoInput.expectsMediaDataInRealTime = YES;
        _assetWriterVideoInput.transform = CGAffineTransformIdentity;
        
        if (additional != nil) {
            NSNumber *angle = additional[XMVideoRecorderVideoRotation];
            if (angle) {
                _assetWriterVideoInput.transform = CGAffineTransformMakeRotation([angle floatValue]);
            }
        }
        
        if (_assetWriterVideoInput && [_assetWriter canAddInput:_assetWriterVideoInput]) {
            [_assetWriter addInput:_assetWriterVideoInput];
            
#if !defined(NDEBUG) && LOG_WRITER
            NSDictionary *videoCompressionProperties = videoSettings[AVVideoCompressionPropertiesKey];
            if (videoCompressionProperties) {
                DLog(@"setup video with compression settings bps (%f) frameInterval (%ld)",
                     [videoCompressionProperties[AVVideoAverageBitRateKey] floatValue],
                     (long)[videoCompressionProperties[AVVideoMaxKeyFrameIntervalKey] integerValue]);
            } else {
                DLog(@"setup video");
            }
#endif
            
        } else {
            DLog(@"couldn't add asset writer video input");
        }
        
    } else {
        
        _assetWriterVideoInput = nil;
        DLog(@"couldn't apply video output settings");
        
    }
    
    return self.isVideoReady;
}

#pragma mark - sample buffer writing

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer withMediaTypeVideo:(BOOL)video
{
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    // setup the writer
    if ( _assetWriter.status == AVAssetWriterStatusUnknown ) {
        
        if ([_assetWriter startWriting]) {
            CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            [_assetWriter startSessionAtSourceTime:timestamp];
            DLog(@"started writing with status (%ld)", (long)_assetWriter.status);
        } else {
            DLog(@"error when starting to write (%@)", [_assetWriter error]);
            return;
        }
        
    }
    
    // check for completion state
    if ( _assetWriter.status == AVAssetWriterStatusFailed ) {
        DLog(@"writer failure, (%@)", _assetWriter.error.localizedDescription);
        return;
    }
    
    if (_assetWriter.status == AVAssetWriterStatusCancelled) {
        DLog(@"writer cancelled");
        return;
    }
    
    if ( _assetWriter.status == AVAssetWriterStatusCompleted) {
        DLog(@"writer finished and completed");
        return;
    }
    
    // perform write
    if ( _assetWriter.status == AVAssetWriterStatusWriting ) {
        
        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        if (duration.value > 0) {
            timestamp = CMTimeAdd(timestamp, duration);
        }
        
        if (video) {
            if (_assetWriterVideoInput.readyForMoreMediaData) {
                if ([_assetWriterVideoInput appendSampleBuffer:sampleBuffer]) {
                    _videoTimestamp = timestamp;
                } else {
                    DLog(@"writer error appending video (%@)", _assetWriter.error);
                }
            }
        } else {
            if (_assetWriterAudioInput.readyForMoreMediaData) {
                if ([_assetWriterAudioInput appendSampleBuffer:sampleBuffer]) {
                    _audioTimestamp = timestamp;
                } else {
                    DLog(@"writer error appending audio (%@)", _assetWriter.error);
                }
            }
        }
        
    }
}

- (void)finishWritingWithCompletionHandler:(void (^)(void))handler
{
    if (_assetWriter.status == AVAssetWriterStatusUnknown ||
        _assetWriter.status == AVAssetWriterStatusCompleted) {
        DLog(@"asset writer was in an unexpected state (%@)", @(_assetWriter.status));
        return;
    }
    [_assetWriterVideoInput markAsFinished];
    [_assetWriterAudioInput markAsFinished];
    [_assetWriter finishWritingWithCompletionHandler:handler];
}

@end
