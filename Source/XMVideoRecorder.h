//
//  XMVideoRecorder.h
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/28.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "XMVideoRecorderPreview.h"

typedef NS_ENUM(NSInteger, XMCameraDevice) {
    XMCameraDeviceBack = 0,
    XMCameraDeviceFront
};

typedef NS_ENUM(NSInteger, XMCameraOrientation) {
    XMCameraOrientationPortrait = AVCaptureVideoOrientationPortrait,
    XMCameraOrientationPortraitUpsideDown = AVCaptureVideoOrientationPortraitUpsideDown,
    XMCameraOrientationLandscapeRight = AVCaptureVideoOrientationLandscapeRight,
    XMCameraOrientationLandscapeLeft = AVCaptureVideoOrientationLandscapeLeft,
};

typedef NS_ENUM(NSInteger, XMFocusMode) {
    XMFocusModeLocked = AVCaptureFocusModeLocked,
    XMFocusModeAutoFocus = AVCaptureFocusModeAutoFocus,
    XMFocusModeContinuousAutoFocus = AVCaptureFocusModeContinuousAutoFocus
};

typedef NS_ENUM(NSInteger, XMExposureMode) {
    XMExposureModeLocked = AVCaptureExposureModeLocked,
    XMExposureModeAutoExpose = AVCaptureExposureModeAutoExpose,
    XMExposureModeContinuousAutoExposure = AVCaptureExposureModeContinuousAutoExposure
};

typedef NS_ENUM(NSInteger, XMTorchMode) {
    XMTorchModeOff = AVCaptureTorchModeOff,
    XMTorchModeOn = AVCaptureTorchModeOn,
    XMTorchModeAuto = AVCaptureTorchModeAuto
};

typedef NS_ENUM(NSInteger, XMMirroringMode) {
    XMMirroringAuto = 0,
    XMMirroringOn,
    XMMirroringOff
};

typedef NS_ENUM(NSInteger, XMOutputFormat) {
    XMOutputFormatPreset = 0,
    XMOutputFormatSquare, // 1:1
    XMOutputFormatWidescreen, // 16:9
    XMOutputFormatStandard // 4:3
};

NS_ASSUME_NONNULL_BEGIN

// XMError

extern NSString * const XMVideoRecorderErrorDomain;

typedef NS_ENUM(NSInteger, XMVideoRecorderErrorType)
{
    XMVideoRecorderErrorUnknown = -1,
    XMVideoRecorderErrorCancelled = 100,
    XMVideoRecorderErrorSessionFailed = 101,
    XMVideoRecorderErrorBadOutputFile = 102,
    XMVideoRecorderErrorOutputFileExists = 103,
    XMVideoRecorderErrorCaptureFailed = 104,
};

// additional video capture keys
extern NSString * const XMVideoRecorderVideoRotation;
// photo dictionary keys
extern NSString * const XMVideoRecorderPhotoMetadataKey;
extern NSString * const XMVideoRecorderPhotoJPEGKey;
extern NSString * const XMVideoRecorderPhotoImageKey;
extern NSString * const XMVideoRecorderPhotoThumbnailKey; // 160x120

// video dictionary keys
extern NSString * const XMVideoRecorderVideoPathKey;
extern NSString * const XMVideoRecorderVideoThumbnailKey;
extern NSString * const XMVideoRecorderVideoThumbnailArrayKey;
extern NSString * const XMVideoRecorderVideoCapturedDurationKey; // Captured duration in seconds

// suggested videoBitRate constants
static CGFloat const XMVideoBitRate480x360 = 87500 * 8;
static CGFloat const XMVideoBitRate640x480 = 437500 * 8;
static CGFloat const XMVideoBitRate1280x720 = 1312500 * 8;
static CGFloat const XMVideoBitRate1920x1080 = 2975000 * 8;
static CGFloat const XMVideoBitRate960x540 = 3750000 * 8;
static CGFloat const XMVideoBitRate1280x750 = 5000000 * 8;



@protocol XMVideoRecorderDelegate;
@interface XMVideoRecorder : NSObject

@property (nonatomic, weak, nullable) id<XMVideoRecorderDelegate> delegate;
// session
@property (nonatomic, readonly, getter=isCaptureSessionActive) BOOL captureSessionActive;
// setup
@property (nonatomic) XMCameraOrientation cameraOrientation;
@property (nonatomic) XMCameraDevice cameraDevice;
//使用自己配置的AVAudioSession，停止AVCaptureSession对AVAudioSession的自动设置，比如支持蓝牙耳机的录制就要设置成YES。
@property (nonatomic) BOOL usesApplicationAudioSession;
@property (nonatomic) XMTorchMode torchMode; // torch
@property (nonatomic, readonly, getter=isTorchAvailable) BOOL torchAvailable;
@property (nonatomic) XMMirroringMode mirroringMode;
// video output settings
@property (nonatomic, copy) NSDictionary *additionalVideoProperties;
@property (nonatomic, copy) NSString *captureSessionPreset;
@property (nonatomic, copy) NSString *captureDirectory;
@property (nonatomic) XMOutputFormat outputFormat;
// video compression settings
@property (nonatomic) CGFloat videoBitRate;
@property (nonatomic) NSDictionary *additionalCompressionProperties;
// video frame rate (adjustment may change the capture format (AVCaptureDeviceFormat : FoV, zoom factor, etc)
@property (nonatomic) NSInteger videoFrameRate; // desired fps for active cameraDevice
// preview
@property (nonatomic, readonly) XMVideoRecorderPreview *preview;
@property (nonatomic, readonly) CGRect cleanAperture;
// focus, exposure
@property (nonatomic) XMFocusMode focusMode;
@property (nonatomic) XMExposureMode exposureMode;
//zoomFactor
@property (nonatomic, readonly) NSUInteger maxZoomFactor;
@property (nonatomic, readonly) NSUInteger minZoomFactor;
// video
@property (nonatomic, readonly) BOOL supportsVideoCapture;
@property (nonatomic, readonly) BOOL canCaptureVideo;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
@property (nonatomic, getter=isAudioCaptureEnabled) BOOL audioCaptureEnabled;
@property (nonatomic, readonly) EAGLContext *context;
@property (nonatomic) CMTime maximumCaptureDuration;
@property (nonatomic, readonly) Float64 capturedAudioSeconds;
@property (nonatomic, readonly) Float64 capturedVideoSeconds;
// thumbnails
@property (nonatomic) BOOL thumbnailEnabled; // thumbnail generation, disabling reduces processing time for a photo or video


+ (XMVideoRecorder *)sharedInstance;

- (BOOL)supportsVideoFrameRate:(NSInteger)videoFrameRate;
- (void)startPreview;
- (void)stopPreview;
// note: focus and exposure modes change when adjusting on point
- (void)adjustFocusExposureAndWhiteBalance;
- (BOOL)isFocusPointOfInterestSupported;
- (void)focusExposeAndAdjustWhiteBalanceAtAdjustedPoint:(CGPoint)adjustedPoint;
- (void)focusAtAdjustedPointOfInterest:(CGPoint)adjustedPoint;
- (BOOL)isAdjustingFocus;
- (void)exposeAtAdjustedPointOfInterest:(CGPoint)adjustedPoint;
- (BOOL)isAdjustingExposure;
- (void)setVideoZoomFactor:(CGFloat)factor withRate:(float)rate;
// photo
- (void)captureVideoFrameAsPhoto;
// video
- (void)startVideoCapture;
- (void)pauseVideoCapture;
- (void)resumeVideoCapture;
- (void)endVideoCapture;
- (void)cancelVideoCapture;
// thumbnails
- (void)captureCurrentVideoThumbnail;
- (void)captureVideoThumbnailAtFrame:(int64_t)frame;
- (void)captureVideoThumbnailAtTime:(Float64)seconds;

@end



@protocol XMVideoRecorderDelegate <NSObject>
@optional

// session
- (void)recorderSessionWillStart:(XMVideoRecorder *)recorder;
- (void)recorderSessionDidStart:(XMVideoRecorder *)recorder;
- (void)recorderSessionDidStop:(XMVideoRecorder *)recorder;
- (void)recorderSessionWasInterrupted:(XMVideoRecorder *)recorder;
- (void)recorderSessionInterruptionEnded:(XMVideoRecorder *)recorder;
// device / format
- (void)recorderCameraDeviceWillChange:(XMVideoRecorder *)recorder;
- (void)recorderCameraDeviceDidChange:(XMVideoRecorder *)recorder;
- (void)recorderOutputFormatWillChange:(XMVideoRecorder *)recorder;
- (void)recorderOutputFormatDidChange:(XMVideoRecorder *)recorder;
- (void)recorder:(XMVideoRecorder *)recorder didChangeCleanAperture:(CGRect)cleanAperture;
- (void)recorderDidChangeVideoFormatAndFrameRate:(XMVideoRecorder *)recorder;
// focus / exposure
- (void)recorderWillStartFocus:(XMVideoRecorder *)recorder;
- (void)recorderDidStopFocus:(XMVideoRecorder *)recorder;
- (void)recorderWillChangeExposure:(XMVideoRecorder *)recorder;
- (void)recorderDidChangeExposure:(XMVideoRecorder *)recorder;
- (void)recorderDidChangeTorchMode:(XMVideoRecorder *)recorder; // torch was changed
- (void)recorderDidChangeTorchAvailablility:(XMVideoRecorder *)recorder; // torch is available
// preview
- (void)recorderSessionDidStartPreview:(XMVideoRecorder *)recorder;
- (void)recorderSessionDidStopPreview:(XMVideoRecorder *)recorder;
// photo
- (void)recorderWillCapturePhoto:(XMVideoRecorder *)recorder;
- (void)recorderDidCapturePhoto:(XMVideoRecorder *)recorder;
- (void)recorder:(XMVideoRecorder *)recorder capturedPhoto:(nullable NSDictionary *)photoDict error:(nullable NSError *)error;
// video
- (CVPixelBufferRef)recorderWillRenderAndWritePixelBuffer:(CVPixelBufferRef)orginPixelBuffer;
- (NSString *)recorder:(XMVideoRecorder *)recorder willStartVideoCaptureToFile:(NSString *)fileName;
- (void)recorderDidStartVideoCapture:(XMVideoRecorder *)recorder;
- (void)recorderDidPauseVideoCapture:(XMVideoRecorder *)recorder; // stopped but not ended
- (void)recorderDidResumeVideoCapture:(XMVideoRecorder *)recorder;
- (void)recorderDidEndVideoCapture:(XMVideoRecorder *)recorder;
- (void)recorder:(XMVideoRecorder *)recorder capturedVideo:(nullable NSDictionary *)videoDict error:(nullable NSError *)error;
// video capture progress
- (void)recorder:(XMVideoRecorder *)recorder didCaptureVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)recorder:(XMVideoRecorder *)recorder didCaptureAudioSample:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END

