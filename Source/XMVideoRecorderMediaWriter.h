//
//  XMVideoRecorderMediaWriter.h
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/29.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@interface XMVideoRecorderMediaWriter : NSObject

@property (nonatomic, readonly) NSURL *outputURL;
@property (nonatomic, readonly) NSError *error;
// time durations
@property (nonatomic, readonly) CMTime audioTimestamp;
@property (nonatomic, readonly) CMTime videoTimestamp;
// meida is available
@property (nonatomic, readonly, getter=isAudioReady) BOOL audioReady;
@property (nonatomic, readonly, getter=isVideoReady) BOOL videoReady;

- (id)initWithOutputURL:(NSURL *)outputURL;

// configure settings before writing
- (BOOL)setupAudioWithSettings:(NSDictionary *)audioSettings;
- (BOOL)setupVideoWithSettings:(NSDictionary *)videoSettings withAdditional:(NSDictionary *)additional;

// write methods
- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer withMediaTypeVideo:(BOOL)video;
- (void)finishWritingWithCompletionHandler:(void (^)(void))handler;

@end
