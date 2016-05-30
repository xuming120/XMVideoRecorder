//
//  XMVideoRecorder.m
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/28.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import "XMVideoRecorder.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "XMVideoRecorderUtilities.h"
#import "XMVideoRecorderMediaWriter.h"

#define LOG_RECORDER 1
#ifndef DLog
#if !defined(NDEBUG) && LOG_RECORDER
#   define DLog(fmt, ...) NSLog((@"recorder: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif
#endif

static uint64_t const XMVideoRecorderRequiredMinimumDiskSpaceInBytes = 49999872; // ~ 47 MB
static CGFloat const XMVideoRecorderThumbnailWidth = 160.0f;

NSString * const XMVideoRecorderErrorDomain = @"XMVideoRecorderErrorDomain";
// additional video capture keys
NSString * const XMVideoRecorderVideoRotation = @"XMVideoRecorderVideoRotation";
// photo dictionary key definitions
NSString * const XMVideoRecorderPhotoMetadataKey = @"XMVideoRecorderPhotoMetadataKey";
NSString * const XMVideoRecorderPhotoJPEGKey = @"XMVideoRecorderPhotoJPEGKey";
NSString * const XMVideoRecorderPhotoImageKey = @"XMVideoRecorderPhotoImageKey";
NSString * const XMVideoRecorderPhotoThumbnailKey = @"XMVideoRecorderPhotoThumbnailKey";
// video dictionary key definitions
NSString * const XMVideoRecorderVideoPathKey = @"XMVideoRecorderVideoPathKey";
NSString * const XMVideoRecorderVideoThumbnailKey = @"XMVideoRecorderVideoThumbnailKey";
NSString * const XMVideoRecorderVideoThumbnailArrayKey = @"XMVideoRecorderVideoThumbnailArrayKey";
NSString * const XMVideoRecorderVideoCapturedDurationKey = @"XMVideoRecorderVideoCapturedDurationKey";

// KVO contexts
static NSString * const XMVideoRecorderFocusObserverContext = @"XMVideoRecorderFocusObserverContext";
static NSString * const XMVideoRecorderExposureObserverContext = @"XMVideoRecorderExposureObserverContext";
static NSString * const XMVideoRecorderWhiteBalanceObserverContext = @"XMVideoRecorderWhiteBalanceObserverContext";
static NSString * const XMVideoRecorderTorchModeObserverContext = @"XMVideoRecorderTorchModeObserverContext";
static NSString * const XMVideoRecorderTorchAvailabilityObserverContext = @"XMVideoRecorderTorchAvailabilityObserverContext";


@interface XMVideoRecorder () <AVCaptureAudioDataOutputSampleBufferDelegate,AVCaptureVideoDataOutputSampleBufferDelegate>
{
    // AV
    AVCaptureSession *_captureSession;
    
    AVCaptureDevice *_captureDeviceFront;
    AVCaptureDevice *_captureDeviceBack;
    AVCaptureDevice *_captureDeviceAudio;
    
    AVCaptureDeviceInput *_captureDeviceInputFront;
    AVCaptureDeviceInput *_captureDeviceInputBack;
    AVCaptureDeviceInput *_captureDeviceInputAudio;
    
    AVCaptureAudioDataOutput *_captureOutputAudio;
    AVCaptureVideoDataOutput *_captureOutputVideo;
    
    XMVideoRecorderMediaWriter *_mediaWriter;
    
    dispatch_queue_t _captureSessionDispatchQueue;
    dispatch_queue_t _captureCaptureDispatchQueue;
    
    
    NSMutableSet* _captureThumbnailTimes;
    NSMutableSet* _captureThumbnailFrames;
    
    AVCaptureDeviceInput *_currentInput;
    AVCaptureOutput *_currentOutput;
    
    CMTime _startTimestamp;
    CMTime _timeOffset;
    NSInteger _videoFrameRate;
    
    CIContext *_ciContext;
    
    BOOL isInbackground;
    
    // flags
    struct {
        unsigned int previewRunning:1;
        unsigned int changingModes:1;
        unsigned int recording:1;
        unsigned int paused:1;
        unsigned int interrupted:1;
        unsigned int videoWritten:1;
        unsigned int audioCaptureEnabled:1;
        unsigned int thumbnailEnabled:1;
        unsigned int videoCaptureFrame:1;
    } __block _flags;
    
}

@property (nonatomic) AVCaptureDevice *currentDevice;
@property(nonatomic, retain) __attribute__((NSObject)) CVPixelBufferRef currentPreviewPixelBuffer;

@end

@implementation XMVideoRecorder

#pragma mark - init dealloc
+ (XMVideoRecorder *)sharedInstance
{
    static XMVideoRecorder *singleton = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        singleton = [[XMVideoRecorder alloc] init];
    });
    return singleton;
}

- (id)init
{
    self = [super init];
    if (self) {
        // setup GLES
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (!_context) {
            DLog(@"failed to create GL context");
        }
        _ciContext = [CIContext contextWithEAGLContext:_context];
        
        
        _captureSessionPreset = AVCaptureSessionPreset640x480;
        _captureDirectory = nil;
        
        _usesApplicationAudioSession = NO;
        
        // Average bytes per second based on video dimensions
        // lower the bitRate, higher the compression
        _videoBitRate = XMVideoBitRate640x480;
        
        // default flags
        _flags.thumbnailEnabled = YES;
        _flags.audioCaptureEnabled = YES;
        
        // setup queues
        _captureSessionDispatchQueue = dispatch_queue_create("XMVideoRecorderSession", DISPATCH_QUEUE_SERIAL); // protects session
        _captureCaptureDispatchQueue = dispatch_queue_create("XMVideoRecorderCapture", DISPATCH_QUEUE_SERIAL); // protects capture

        _preview = [[XMVideoRecorderPreview alloc] initWithFrame:CGRectZero];
        _preview.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
        
        
        _maximumCaptureDuration = kCMTimeInvalid;
        _minZoomFactor = 1;
        _maxZoomFactor = 3;
        
        [self setMirroringMode:XMMirroringAuto];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:[UIApplication sharedApplication]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:[UIApplication sharedApplication]];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _delegate = nil;
    
    [self _destroyCamera];
    
    if ( _currentPreviewPixelBuffer ) {
        CFRelease( _currentPreviewPixelBuffer );
    }
}


#pragma mark - getters/setters

- (BOOL)isVideoWritten
{
    return _flags.videoWritten;
}

- (BOOL)isCaptureSessionActive
{
    return ([_captureSession isRunning]);
}

- (BOOL)isRecording
{
    return _flags.recording;
}

- (BOOL)isPaused
{
    return _flags.paused;
}

- (void)setAudioCaptureEnabled:(BOOL)audioCaptureEnabled
{
    _flags.audioCaptureEnabled = (unsigned int)audioCaptureEnabled;
}

- (BOOL)isAudioCaptureEnabled
{
    return _flags.audioCaptureEnabled;
}

- (void)setThumbnailEnabled:(BOOL)thumbnailEnabled
{
    _flags.thumbnailEnabled = (unsigned int)thumbnailEnabled;
}

- (BOOL)thumbnailEnabled
{
    return _flags.thumbnailEnabled;
}

- (Float64)capturedAudioSeconds
{
    if (_mediaWriter && CMTIME_IS_VALID(_mediaWriter.audioTimestamp)) {
        return CMTimeGetSeconds(CMTimeSubtract(_mediaWriter.audioTimestamp, _startTimestamp));
    } else {
        return 0.0;
    }
}

- (Float64)capturedVideoSeconds
{
    if (_mediaWriter && CMTIME_IS_VALID(_mediaWriter.videoTimestamp)) {
        return CMTimeGetSeconds(CMTimeSubtract(_mediaWriter.videoTimestamp, _startTimestamp));
    } else {
        return 0.0;
    }
}

- (void)setCameraOrientation:(XMCameraOrientation)cameraOrientation
{
    if (cameraOrientation == _cameraOrientation)
        return;
    _cameraOrientation = cameraOrientation;
}

- (void)_setOrientationForConnection:(AVCaptureConnection *)connection
{
    if (!connection || ![connection isVideoOrientationSupported])
        return;
    
    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
    switch (_cameraOrientation) {
        case XMCameraOrientationPortraitUpsideDown:
            orientation = AVCaptureVideoOrientationPortraitUpsideDown;
            break;
        case XMCameraOrientationLandscapeRight:
            orientation = AVCaptureVideoOrientationLandscapeRight;
            break;
        case XMCameraOrientationLandscapeLeft:
            orientation = AVCaptureVideoOrientationLandscapeLeft;
            break;
        case XMCameraOrientationPortrait:
        default:
            break;
    }
    
    [connection setVideoOrientation:orientation];
}

- (void)_setCameraDevice:(XMCameraDevice)cameraDevice outputFormat:(XMOutputFormat)outputFormat
{
    BOOL changeDevice = (_cameraDevice != cameraDevice);
    BOOL changeOutputFormat = (_outputFormat != outputFormat);
    
    DLog(@"change device (%d) format (%d)", changeDevice, changeOutputFormat);
    
    if (!changeDevice && !changeOutputFormat) {
        return;
    }
    
    if (changeDevice && [_delegate respondsToSelector:@selector(recorderCameraDeviceWillChange:)]) {
        [_delegate performSelector:@selector(recorderCameraDeviceWillChange:) withObject:self];
    }
    if (changeOutputFormat && [_delegate respondsToSelector:@selector(recorderOutputFormatWillChange:)]) {
        [_delegate performSelector:@selector(recorderOutputFormatWillChange:) withObject:self];
    }
    
    _flags.changingModes = YES;
    
    _cameraDevice = cameraDevice;
    _outputFormat = outputFormat;
    
    XMVideoRecorderBlock didChangeBlock = ^{
        _flags.changingModes = NO;
        
        if (changeDevice && [_delegate respondsToSelector:@selector(recorderCameraDeviceDidChange:)]) {
            [_delegate performSelector:@selector(recorderCameraDeviceDidChange:) withObject:self];
        }
        if (changeOutputFormat && [_delegate respondsToSelector:@selector(recorderOutputFormatDidChange:)]) {
            [_delegate performSelector:@selector(recorderOutputFormatDidChange:) withObject:self];
        }
    };
    
    // since there is no session in progress, set and bail
    if (!_captureSession) {
        _flags.changingModes = NO;
        
        didChangeBlock();
        
        return;
    }
    
    [self _enqueueBlockOnCaptureSessionQueue:^{
        // camera is already setup, no need to call _setupCamera
        [self _setupSession];
        
        [self setMirroringMode:_mirroringMode];
        
        [self _enqueueBlockOnMainQueue:didChangeBlock];
    }];
}

- (void)setCameraDevice:(XMCameraDevice)cameraDevice
{
    [self _setCameraDevice:cameraDevice outputFormat:_outputFormat];
}

- (void)setCaptureSessionPreset:(NSString *)captureSessionPreset
{
    _captureSessionPreset = captureSessionPreset;
    if ([_captureSession canSetSessionPreset:captureSessionPreset]){
        [self _commitBlock:^{
            [_captureSession setSessionPreset:captureSessionPreset];
        }];
    }
}

- (void)setOutputFormat:(XMOutputFormat)outputFormat
{
    [self _setCameraDevice:_cameraDevice outputFormat:outputFormat];
}

- (BOOL)isFocusPointOfInterestSupported
{
    return [_currentDevice isFocusPointOfInterestSupported];
}

- (void)setFocusMode:(XMFocusMode)focusMode
{
    BOOL shouldChangeFocusMode = (_focusMode != focusMode);
    if (![_currentDevice isFocusModeSupported:(AVCaptureFocusMode)focusMode] || !shouldChangeFocusMode)
        return;
    
    _focusMode = focusMode;
    
    NSError *error = nil;
    if (_currentDevice && [_currentDevice lockForConfiguration:&error]) {
        [_currentDevice setFocusMode:(AVCaptureFocusMode)focusMode];
        [_currentDevice unlockForConfiguration];
    } else if (error) {
        DLog(@"error locking device for focus mode change (%@)", error);
    }
}

- (void)setExposureMode:(XMExposureMode)exposureMode
{
    BOOL shouldChangeExposureMode = (_exposureMode != exposureMode);
    if (![_currentDevice isExposureModeSupported:(AVCaptureExposureMode)exposureMode] || !shouldChangeExposureMode)
        return;
    
    _exposureMode = exposureMode;
    
    NSError *error = nil;
    if (_currentDevice && [_currentDevice lockForConfiguration:&error]) {
        [_currentDevice setExposureMode:(AVCaptureExposureMode)exposureMode];
        [_currentDevice unlockForConfiguration];
    } else if (error) {
        DLog(@"error locking device for exposure mode change (%@)", error);
    }
    
}

- (void) _setCurrentDevice:(AVCaptureDevice *)device
{
    _currentDevice  = device;
    _exposureMode   = (XMExposureMode)device.exposureMode;
    _focusMode      = (XMFocusMode)device.focusMode;
    _maxZoomFactor  = _currentDevice.activeFormat.videoMaxZoomFactor > 3 ? 3 : _currentDevice.activeFormat.videoMaxZoomFactor;
}

- (BOOL)isTorchAvailable
{
    return (_currentDevice && [_currentDevice hasTorch]);
}

- (void)setTorchMode:(XMTorchMode)torchMode
{
    BOOL shouldChangeTorchMode = (_torchMode != torchMode);
    if (![_currentDevice hasTorch] || !shouldChangeTorchMode)
        return;
    
    _torchMode = torchMode;
    
    NSError *error = nil;
    if (_currentDevice && [_currentDevice lockForConfiguration:&error]) {
        if ([_currentDevice isTorchModeSupported:(AVCaptureTorchMode)_torchMode]) {
            [_currentDevice setTorchMode:(AVCaptureTorchMode)_torchMode];
        }
        [_currentDevice unlockForConfiguration];
    } else if (error) {
        DLog(@"error locking device for torch mode change (%@)", error);
    }
}

//zoomFactor
- (void)setVideoZoomFactor:(CGFloat)factor withRate:(float)rate
{
    if (factor >= _minZoomFactor && factor <= _maxZoomFactor) {
        NSError *error = nil;
        if ([_currentDevice lockForConfiguration:&error]) {
            [_currentDevice rampToVideoZoomFactor:factor withRate:rate];
            [_currentDevice unlockForConfiguration];
        } else if (error) {
            DLog(@"error locking device for zoom factor change (%@)", error);
        }
    }
}

// framerate

- (void)setVideoFrameRate:(NSInteger)videoFrameRate
{
    if (![self supportsVideoFrameRate:videoFrameRate]) {
        DLog(@"frame rate range not supported for current device format");
        return;
    }
    
    BOOL isRecording = _flags.recording;
    if (isRecording) {
        [self pauseVideoCapture];
    }
    
    CMTime fps = CMTimeMake(1, (int32_t)videoFrameRate);
    
    AVCaptureDevice *videoDevice = _currentDevice;
    AVCaptureDeviceFormat *supportingFormat = nil;
    int32_t maxWidth = 0;
    
    NSArray *formats = [videoDevice formats];
    for (AVCaptureDeviceFormat *format in formats) {
        NSArray *videoSupportedFrameRateRanges = format.videoSupportedFrameRateRanges;
        for (AVFrameRateRange *range in videoSupportedFrameRateRanges) {
            
            CMFormatDescriptionRef desc = format.formatDescription;
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(desc);
            int32_t width = dimensions.width;
            if (range.minFrameRate <= videoFrameRate && videoFrameRate <= range.maxFrameRate && width >= maxWidth) {
                supportingFormat = format;
                maxWidth = width;
            }
            
        }
    }
    
    if (supportingFormat) {
        NSError *error = nil;
        [_captureSession beginConfiguration];  // the session to which the receiver's AVCaptureDeviceInput is added.
        if ([_currentDevice lockForConfiguration:&error]) {
            [_currentDevice setActiveFormat:supportingFormat];
            _currentDevice.activeVideoMinFrameDuration = fps;
            _currentDevice.activeVideoMaxFrameDuration = fps;
            _videoFrameRate = videoFrameRate;
            [_currentDevice unlockForConfiguration];
        } else if (error) {
            DLog(@"error locking device for frame rate change (%@)", error);
        }
    }
    [_captureSession commitConfiguration];
    [self _enqueueBlockOnMainQueue:^{
        if ([_delegate respondsToSelector:@selector(recorderDidChangeVideoFormatAndFrameRate:)])
            [_delegate recorderDidChangeVideoFormatAndFrameRate:self];
    }];
    
    if (isRecording) {
        [self resumeVideoCapture];
    }
}

- (NSInteger)videoFrameRate
{
    if (!_currentDevice)
        return 0;
    
    return _currentDevice.activeVideoMaxFrameDuration.timescale;
}

- (BOOL)supportsVideoFrameRate:(NSInteger)videoFrameRate
{
    AVCaptureDevice *videoDevice = nil;
    NSArray *videoDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    NSPredicate *predicate = nil;
    if (self.cameraDevice == XMCameraDeviceBack) {
        predicate = [NSPredicate predicateWithFormat:@"position == %i", AVCaptureDevicePositionBack];
    } else {
        predicate = [NSPredicate predicateWithFormat:@"position == %i", AVCaptureDevicePositionFront];
    }
    NSArray *filteredDevices = [videoDevices filteredArrayUsingPredicate:predicate];
    if (filteredDevices.count > 0) {
        videoDevice = filteredDevices.firstObject;
    } else {
        return NO;
    }
    NSArray *formats = [videoDevice formats];
    for (AVCaptureDeviceFormat *format in formats) {
        NSArray *videoSupportedFrameRateRanges = [format videoSupportedFrameRateRanges];
        for (AVFrameRateRange *frameRateRange in videoSupportedFrameRateRanges) {
            if ( (frameRateRange.minFrameRate <= videoFrameRate) && (videoFrameRate <= frameRateRange.maxFrameRate) ) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)setMirroringMode:(XMMirroringMode)mirroringMode
{
    _mirroringMode = mirroringMode;
    
    AVCaptureConnection *videoConnection = [_currentOutput connectionWithMediaType:AVMediaTypeVideo];
    
    switch (_mirroringMode) {
        case XMMirroringOff:
        {
            if ([videoConnection isVideoMirroringSupported]) {
                [videoConnection setVideoMirrored:NO];
            }
            break;
        }
        case XMMirroringOn:
        {
            if ([videoConnection isVideoMirroringSupported]) {
                [videoConnection setVideoMirrored:YES];
            }
            break;
        }
        case XMMirroringAuto:
        default:
        {
            if ([videoConnection isVideoMirroringSupported]) {
                BOOL mirror = (_cameraDevice == XMCameraDeviceFront);
                [videoConnection setVideoMirrored:mirror];
            }
            
            break;
        }
    }
}

#pragma mark - focus, exposure, white balance

- (void)_focusStarted
{
    //    DLog(@"focus started");
    if ([_delegate respondsToSelector:@selector(recorderWillStartFocus:)])
        [_delegate recorderWillStartFocus:self];
}

- (void)_focusEnded
{
    AVCaptureFocusMode focusMode = [_currentDevice focusMode];
//    BOOL isFocusing = [_currentDevice isAdjustingFocus];
    BOOL isAutoFocusEnabled = (focusMode == AVCaptureFocusModeAutoFocus ||
                               focusMode == AVCaptureFocusModeContinuousAutoFocus);
    if (/*!isFocusing && */isAutoFocusEnabled) {
        NSError *error = nil;
        if ([_currentDevice lockForConfiguration:&error]) {
            
            [_currentDevice setSubjectAreaChangeMonitoringEnabled:YES];
            [_currentDevice unlockForConfiguration];
            
        } else if (error) {
            DLog(@"error locking device post exposure for subject area change monitoring (%@)", error);
        }
    }
    
    if ([_delegate respondsToSelector:@selector(recorderDidStopFocus:)])
        [_delegate recorderDidStopFocus:self];
    //    DLog(@"focus ended");
}

- (void)_exposureChangeStarted
{
    //    DLog(@"exposure change started");
    if ([_delegate respondsToSelector:@selector(recorderWillChangeExposure:)])
        [_delegate recorderWillChangeExposure:self];
}

- (void)_exposureChangeEnded
{
    BOOL isContinuousAutoExposureEnabled = [_currentDevice exposureMode] == AVCaptureExposureModeContinuousAutoExposure;
//    BOOL isExposing = [_currentDevice isAdjustingExposure];
    BOOL isFocusSupported = [_currentDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus];
    
    if (isContinuousAutoExposureEnabled /*&& !isExposing*/ && !isFocusSupported) {
        
        NSError *error = nil;
        if ([_currentDevice lockForConfiguration:&error]) {
            
            [_currentDevice setSubjectAreaChangeMonitoringEnabled:YES];
            [_currentDevice unlockForConfiguration];
            
        } else if (error) {
            DLog(@"error locking device post exposure for subject area change monitoring (%@)", error);
        }
        
    }
    
    if ([_delegate respondsToSelector:@selector(recorderDidChangeExposure:)])
        [_delegate recorderDidChangeExposure:self];
    //    DLog(@"exposure change ended");
}

- (void)_whiteBalanceChangeStarted
{
}

- (void)_whiteBalanceChangeEnded
{
}

- (void)focusAtAdjustedPointOfInterest:(CGPoint)adjustedPoint
{
//    if ([_currentDevice isAdjustingFocus] || [_currentDevice isAdjustingExposure])
//        return;
    
    NSError *error = nil;
    if ([_currentDevice lockForConfiguration:&error]) {
        
        BOOL isFocusAtPointSupported = [_currentDevice isFocusPointOfInterestSupported];
        
        if (isFocusAtPointSupported && [_currentDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
            AVCaptureFocusMode fm = [_currentDevice focusMode];
            [_currentDevice setFocusPointOfInterest:[self _convertToPointOfInterestFromViewCoordinates:adjustedPoint inFrame:_preview.frame]];
            [_currentDevice setFocusMode:fm];
        }
        [_currentDevice unlockForConfiguration];
        
    } else if (error) {
        DLog(@"error locking device for focus adjustment (%@)", error);
    }
}

- (BOOL)isAdjustingFocus
{
    return [_currentDevice isAdjustingFocus];
}

- (void)exposeAtAdjustedPointOfInterest:(CGPoint)adjustedPoint
{
//    if ([_currentDevice isAdjustingExposure])
//        return;
    
    NSError *error = nil;
    if ([_currentDevice lockForConfiguration:&error]) {
        
        BOOL isExposureAtPointSupported = [_currentDevice isExposurePointOfInterestSupported];
        if (isExposureAtPointSupported && [_currentDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            AVCaptureExposureMode em = [_currentDevice exposureMode];
            [_currentDevice setExposurePointOfInterest:[self _convertToPointOfInterestFromViewCoordinates:adjustedPoint inFrame:_preview.frame]];
            [_currentDevice setExposureMode:em];
        }
        [_currentDevice unlockForConfiguration];
        
    } else if (error) {
        DLog(@"error locking device for exposure adjustment (%@)", error);
    }
}

- (BOOL)isAdjustingExposure
{
    return [_currentDevice isAdjustingExposure];
}

- (void)adjustFocusExposureAndWhiteBalance
{
//    if ([_currentDevice isAdjustingFocus] || [_currentDevice isAdjustingExposure])
//        return;
    
    // only notify clients when focus is triggered from an event
    if ([_delegate respondsToSelector:@selector(recorderWillStartFocus:)])
        [_delegate recorderWillStartFocus:self];
    
    CGPoint focusPoint = _preview.center;
    [self focusExposeAndAdjustWhiteBalanceAtAdjustedPoint:focusPoint];
}

// focusExposeAndAdjustWhiteBalanceAtAdjustedPoint: will put focus and exposure into auto
- (void)focusExposeAndAdjustWhiteBalanceAtAdjustedPoint:(CGPoint)adjustedPoint
{
//    if ([_currentDevice isAdjustingFocus] || [_currentDevice isAdjustingExposure])
//        return;
    
    NSError *error = nil;
    if ([_currentDevice lockForConfiguration:&error]) {
        
        BOOL isFocusAtPointSupported = [_currentDevice isFocusPointOfInterestSupported];
        BOOL isExposureAtPointSupported = [_currentDevice isExposurePointOfInterestSupported];
        BOOL isWhiteBalanceModeSupported = [_currentDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        
        if (isFocusAtPointSupported && [_currentDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            [_currentDevice setFocusPointOfInterest:[self _convertToPointOfInterestFromViewCoordinates:adjustedPoint inFrame:_preview.frame]];
            [_currentDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
        }
        
        if (isExposureAtPointSupported && [_currentDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            [_currentDevice setExposurePointOfInterest:[self _convertToPointOfInterestFromViewCoordinates:adjustedPoint inFrame:_preview.frame]];
            [_currentDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
        }
        
        if (isWhiteBalanceModeSupported) {
            [_currentDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        }
        
        [_currentDevice setSubjectAreaChangeMonitoringEnabled:NO];
        
        [_currentDevice unlockForConfiguration];
        
    } else if (error) {
        DLog(@"error locking device for focus / exposure / white-balance adjustment (%@)", error);
    }
}

#pragma mark - queue helper methods

typedef void (^XMVideoRecorderBlock)();

- (void)_enqueueBlockOnCaptureSessionQueue:(XMVideoRecorderBlock)block
{
    dispatch_async(_captureSessionDispatchQueue, ^{
        block();
    });
}

- (void)_enqueueBlockOnCaptureVideoQueue:(XMVideoRecorderBlock)block
{
    dispatch_async(_captureCaptureDispatchQueue, ^{
        block();
    });
}

- (void)_enqueueBlockOnMainQueue:(XMVideoRecorderBlock)block
{
    dispatch_async(dispatch_get_main_queue(), ^{
        block();
    });
}

- (void)_executeBlockOnMainQueue:(XMVideoRecorderBlock)block
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        block();
    });
}

- (void)_commitBlock:(XMVideoRecorderBlock)block
{
    [_captureSession beginConfiguration];
    block();
    [_captureSession commitConfiguration];
}

- (CGPoint)_convertToPointOfInterestFromViewCoordinates:(CGPoint)viewCoordinates inFrame:(CGRect)frame
{
    CGPoint pointOfInterest = CGPointMake(.5f, .5f);
    
    CGSize apertureSize = _cleanAperture.size;
    CGSize frameSize = frame.size;
    
    CGFloat apertureRatio = apertureSize.height / apertureSize.width;
    CGFloat viewRatio = frameSize.width / frameSize.height;
    CGFloat xc = .5f;
    CGFloat yc = .5f;
    if (viewRatio > apertureRatio) {
        CGFloat y2 = apertureSize.width * (frameSize.width / apertureSize.height);
        xc = (viewCoordinates.y + ((y2 - frameSize.height) / 2.f)) / y2;
        yc = (frameSize.width - viewCoordinates.x) / frameSize.width;
    } else {
        CGFloat x2 = apertureSize.height * (frameSize.height / apertureSize.width);
        yc = 1.f - ((viewCoordinates.x + ((x2 - frameSize.width) / 2)) / x2);
        xc = viewCoordinates.y / frameSize.height;
    }
    
    pointOfInterest = CGPointMake(xc, yc);
    
    return pointOfInterest;
}

#pragma mark - camera

// only call from the session queue
- (void)_setupCamera
{
    if (_captureSession)
        return;
    
    // create session
    _captureSession = [[AVCaptureSession alloc] init];
    
    if (_usesApplicationAudioSession) {
        _captureSession.usesApplicationAudioSession = YES;
        _captureSession.automaticallyConfiguresApplicationAudioSession = NO;
    }
    
    // capture devices
    _captureDeviceFront = [XMVideoRecorderUtilities captureDeviceForPosition:AVCaptureDevicePositionFront];
    _captureDeviceBack = [XMVideoRecorderUtilities captureDeviceForPosition:AVCaptureDevicePositionBack];
    
    // capture device inputs
    NSError *error = nil;
    _captureDeviceInputFront = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceFront error:&error];
    if (error) {
        DLog(@"error setting up front camera input (%@)", error);
        error = nil;
    }
    
    _captureDeviceInputBack = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceBack error:&error];
    if (error) {
        DLog(@"error setting up back camera input (%@)", error);
        error = nil;
    }
    
    if (_flags.audioCaptureEnabled) {
        _captureDeviceAudio = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        _captureDeviceInputAudio = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceAudio error:&error];
        
        if (error) {
            DLog(@"error setting up audio input (%@)", error);
        }
    }
    
    // capture device ouputs
    if (_flags.audioCaptureEnabled) {
        _captureOutputAudio = [[AVCaptureAudioDataOutput alloc] init];
    }
    _captureOutputVideo = [[AVCaptureVideoDataOutput alloc] init];
    
    if (_flags.audioCaptureEnabled) {
        [_captureOutputAudio setSampleBufferDelegate:self queue:_captureCaptureDispatchQueue];
    }
    [_captureOutputVideo setSampleBufferDelegate:self queue:_captureCaptureDispatchQueue];
    
    // capture device initial settings
    _videoFrameRate = 30;
    
    // add notification observers
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    // session notifications
    [notificationCenter addObserver:self selector:@selector(_sessionRuntimeErrored:) name:AVCaptureSessionRuntimeErrorNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionStarted:) name:AVCaptureSessionDidStartRunningNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionStopped:) name:AVCaptureSessionDidStopRunningNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:_captureSession];
    
    // capture input notifications
    [notificationCenter addObserver:self selector:@selector(_inputPortFormatDescriptionDidChange:) name:AVCaptureInputPortFormatDescriptionDidChangeNotification object:nil];
    
    // capture device notifications
    [notificationCenter addObserver:self selector:@selector(_deviceSubjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:nil];
    
    // current device KVO notifications
    [self addObserver:self forKeyPath:@"currentDevice.adjustingFocus" options:NSKeyValueObservingOptionNew context:(__bridge void *)XMVideoRecorderFocusObserverContext];
    [self addObserver:self forKeyPath:@"currentDevice.adjustingExposure" options:NSKeyValueObservingOptionNew context:(__bridge void *)XMVideoRecorderExposureObserverContext];
    [self addObserver:self forKeyPath:@"currentDevice.adjustingWhiteBalance" options:NSKeyValueObservingOptionNew context:(__bridge void *)XMVideoRecorderWhiteBalanceObserverContext];
    [self addObserver:self forKeyPath:@"currentDevice.torchMode" options:NSKeyValueObservingOptionNew context:(__bridge void *)XMVideoRecorderTorchModeObserverContext];
    [self addObserver:self forKeyPath:@"currentDevice.torchAvailable" options:NSKeyValueObservingOptionNew context:(__bridge void *)XMVideoRecorderTorchAvailabilityObserverContext];
    
    DLog(@"camera setup");
}

// only call from the session queue
- (void)_destroyCamera
{
    if (!_captureSession)
        return;
    
    // current device KVO notifications
    [self removeObserver:self forKeyPath:@"currentDevice.adjustingFocus"];
    [self removeObserver:self forKeyPath:@"currentDevice.adjustingExposure"];
    [self removeObserver:self forKeyPath:@"currentDevice.adjustingWhiteBalance"];
    [self removeObserver:self forKeyPath:@"currentDevice.torchMode"];
    [self removeObserver:self forKeyPath:@"currentDevice.torchAvailable"];
    
    // remove notification observers (we don't want to just 'remove all' because we're also observing background notifications
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    // session notifications
    [notificationCenter removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionDidStartRunningNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionWasInterruptedNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionInterruptionEndedNotification object:_captureSession];
    
    // capture input notifications
    [notificationCenter removeObserver:self name:AVCaptureInputPortFormatDescriptionDidChangeNotification object:nil];
    
    // capture device notifications
    [notificationCenter removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:nil];
    
    _captureOutputAudio = nil;
    _captureOutputVideo = nil;
    
    _captureDeviceAudio = nil;
    _captureDeviceInputAudio = nil;
    _captureDeviceInputFront = nil;
    _captureDeviceInputBack = nil;
    _captureDeviceFront = nil;
    _captureDeviceBack = nil;
    
    _captureSession = nil;
    _currentDevice = nil;
    _currentInput = nil;
    _currentOutput = nil;
    
    DLog(@"camera destroyed");
}

#pragma mark - AVCaptureSession

- (BOOL)_canSessionCaptureWithOutput:(AVCaptureOutput *)captureOutput
{
    BOOL sessionContainsOutput = [[_captureSession outputs] containsObject:captureOutput];
    BOOL outputHasConnection = ([captureOutput connectionWithMediaType:AVMediaTypeVideo] != nil);
    return (sessionContainsOutput && outputHasConnection);
}

// _setupSession is always called from the captureSession queue
- (void)_setupSession
{
    if (!_captureSession) {
        DLog(@"error, no session running to setup");
        return;
    }
    
    BOOL shouldSwitchDevice = (_currentDevice == nil) ||
    ((_currentDevice == _captureDeviceFront) && (_cameraDevice != XMCameraDeviceFront)) ||
    ((_currentDevice == _captureDeviceBack) && (_cameraDevice != XMCameraDeviceBack));
    
    DLog(@"switchDevice %d", shouldSwitchDevice);
    
    if (!shouldSwitchDevice)
        return;
    
    AVCaptureDeviceInput *newDeviceInput = nil;
    AVCaptureOutput *newCaptureOutput = nil;
    AVCaptureDevice *newCaptureDevice = nil;
    
    [_captureSession beginConfiguration];
    
    // setup session device
    if (shouldSwitchDevice) {
        switch (_cameraDevice) {
            case XMCameraDeviceFront:
            {
                if (_captureDeviceInputBack)
                    [_captureSession removeInput:_captureDeviceInputBack];
                
                if (_captureDeviceInputFront && [_captureSession canAddInput:_captureDeviceInputFront]) {
                    [_captureSession addInput:_captureDeviceInputFront];
                    newDeviceInput = _captureDeviceInputFront;
                    newCaptureDevice = _captureDeviceFront;
                }
                break;
            }
            case XMCameraDeviceBack:
            {
                if (_captureDeviceInputFront)
                    [_captureSession removeInput:_captureDeviceInputFront];
                
                if (_captureDeviceInputBack && [_captureSession canAddInput:_captureDeviceInputBack]) {
                    [_captureSession addInput:_captureDeviceInputBack];
                    newDeviceInput = _captureDeviceInputBack;
                    newCaptureDevice = _captureDeviceBack;
                }
                break;
            }
            default:
                break;
        }
        
    }
    
    if (_currentOutput == nil) {
        
        // audio input
        if ([_captureSession canAddInput:_captureDeviceInputAudio]) {
            [_captureSession addInput:_captureDeviceInputAudio];
        }
        // audio output
        if ([_captureSession canAddOutput:_captureOutputAudio]) {
            [_captureSession addOutput:_captureOutputAudio];
        }
        // video output
        if ([_captureSession canAddOutput:_captureOutputVideo]) {
            [_captureSession addOutput:_captureOutputVideo];
            newCaptureOutput = _captureOutputVideo;
        }
    }
    
    if (!newCaptureDevice)
        newCaptureDevice = _currentDevice;
    
    if (!newCaptureOutput)
        newCaptureOutput = _currentOutput;
    
    // setup video connection
    AVCaptureConnection *videoConnection = [_captureOutputVideo connectionWithMediaType:AVMediaTypeVideo];
    
    // setup input/output
    
    NSString *sessionPreset = _captureSessionPreset;
    
    if ( newCaptureOutput && (newCaptureOutput == _captureOutputVideo) && videoConnection ) {
        
        // setup video orientation
        [self _setOrientationForConnection:videoConnection];
        
        // setup video stabilization, if available
        if ([videoConnection isVideoStabilizationSupported]) {
            if ([videoConnection respondsToSelector:@selector(setPreferredVideoStabilizationMode:)]) {
                [videoConnection setPreferredVideoStabilizationMode:AVCaptureVideoStabilizationModeAuto];
            } else {
                [videoConnection setEnablesVideoStabilizationWhenAvailable:YES];
            }
        }
        
        // discard late frames
        [_captureOutputVideo setAlwaysDiscardsLateVideoFrames:YES];
        
        // specify video preset
        sessionPreset = _captureSessionPreset;
        
        // setup video settings
        NSDictionary *videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
        
        if (videoSettings) {
            [_captureOutputVideo setVideoSettings:videoSettings];
        }
        
        // setup video device configuration
        NSError *error = nil;
        if ([newCaptureDevice lockForConfiguration:&error]) {
            
            // smooth autofocus for videos
            if ([newCaptureDevice isSmoothAutoFocusSupported])
                [newCaptureDevice setSmoothAutoFocusEnabled:YES];
            
            [newCaptureDevice unlockForConfiguration];
            
        } else if (error) {
            DLog(@"error locking device for video device configuration (%@)", error);
        }
        
    }
    
    // apply presets
    if ([_captureSession canSetSessionPreset:sessionPreset])
        [_captureSession setSessionPreset:sessionPreset];
    
    if (newDeviceInput)
        _currentInput = newDeviceInput;
    
    if (newCaptureOutput)
        _currentOutput = newCaptureOutput;
    
    // ensure there is a capture device setup
    if (_currentInput) {
        AVCaptureDevice *device = [_currentInput device];
        if (device) {
            [self willChangeValueForKey:@"currentDevice"];
            [self _setCurrentDevice:device];
            [self didChangeValueForKey:@"currentDevice"];
        }
    }
    
    [_captureSession commitConfiguration];
    
    DLog(@"capture session setup");
}

#pragma mark - preview

- (void)startPreview
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if (!_captureSession) {
            [self _setupCamera];
            [self _setupSession];
        }
        
        [self setMirroringMode:_mirroringMode];
        
        if (![_captureSession isRunning]) {
            [_captureSession startRunning];
            
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(recorderSessionDidStartPreview:)]) {
                    [_delegate recorderSessionDidStartPreview:self];
                }
            }];
            DLog(@"capture session running");
        }
        _flags.previewRunning = YES;
    }];
}

- (void)stopPreview
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if (!_flags.previewRunning)
            return;
        
        if ([_captureSession isRunning])
            [_captureSession stopRunning];
        
        [self _executeBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderSessionDidStopPreview:)]) {
                [_delegate recorderSessionDidStopPreview:self];
            }
        }];
        DLog(@"capture session stopped");
        _flags.previewRunning = NO;
    }];
}

#pragma mark - video

- (BOOL)supportsVideoCapture
{
    return ([[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] count] > 0);
}

- (BOOL)canCaptureVideo
{
    BOOL isDiskSpaceAvailable = [XMVideoRecorderUtilities availableDiskSpaceInBytes] > XMVideoRecorderRequiredMinimumDiskSpaceInBytes;
    return [self supportsVideoCapture] && [self isCaptureSessionActive] && !_flags.changingModes && isDiskSpaceAvailable;
}

- (void)startVideoCapture
{
    if (![self _canSessionCaptureWithOutput:_currentOutput]) {
        [self _failVideoCaptureWithErrorCode:XMVideoRecorderErrorSessionFailed];
        DLog(@"session is not setup properly for capture");
        return;
    }
    
    DLog(@"starting video capture");
    
    [self _enqueueBlockOnCaptureVideoQueue:^{
        
        if (_flags.recording || _flags.paused)
            return;
        
        NSString *guid = [[NSUUID new] UUIDString];
        NSString *outputFile = [NSString stringWithFormat:@"video_%@.mp4", guid];
        
        if ([_delegate respondsToSelector:@selector(recorder:willStartVideoCaptureToFile:)]) {
            outputFile = [_delegate recorder:self willStartVideoCaptureToFile:outputFile];
            
            if (!outputFile) {
                [self _failVideoCaptureWithErrorCode:XMVideoRecorderErrorBadOutputFile];
                return;
            }
        }
        
        NSString *outputDirectory = (_captureDirectory == nil ? NSTemporaryDirectory() : _captureDirectory);
        NSString *outputPath = [outputDirectory stringByAppendingPathComponent:outputFile];
        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:outputPath error:&error]) {
                [self _failVideoCaptureWithErrorCode:XMVideoRecorderErrorOutputFileExists];
                
                DLog(@"could not setup an output file (file exists)");
                return;
            }
        }
        
        if (!outputPath || [outputPath length] == 0) {
            [self _failVideoCaptureWithErrorCode:XMVideoRecorderErrorBadOutputFile];
            
            DLog(@"could not setup an output file");
            return;
        }
        
        if (_mediaWriter) {
            _mediaWriter = nil;
        }
        _mediaWriter = [[XMVideoRecorderMediaWriter alloc] initWithOutputURL:outputURL];
        
        AVCaptureConnection *videoConnection = [_captureOutputVideo connectionWithMediaType:AVMediaTypeVideo];
        [self _setOrientationForConnection:videoConnection];
        
        _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
        _timeOffset = kCMTimeInvalid;
        
        _flags.recording = YES;
        _flags.paused = NO;
        _flags.interrupted = NO;
        _flags.videoWritten = NO;
        
        _captureThumbnailTimes = [NSMutableSet set];
        _captureThumbnailFrames = [NSMutableSet set];
        
        if (_flags.thumbnailEnabled) {
            [self captureVideoThumbnailAtFrame:0];
        }
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderDidStartVideoCapture:)])
                [_delegate recorderDidStartVideoCapture:self];
        }];
    }];
}

- (void)pauseVideoCapture
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        if (!_flags.recording)
            return;
        
        if (!_mediaWriter) {
            DLog(@"media writer unavailable to stop");
            return;
        }
        
        DLog(@"pausing video capture");
        
        _flags.paused = YES;
        _flags.interrupted = YES;
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderDidPauseVideoCapture:)])
                [_delegate recorderDidPauseVideoCapture:self];
        }];
    }];
}

- (void)resumeVideoCapture
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        if (!_flags.recording || !_flags.paused)
            return;
        
        if (!_mediaWriter) {
            DLog(@"media writer unavailable to resume");
            return;
        }
        
        DLog(@"resuming video capture");
        
        _flags.paused = NO;
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderDidResumeVideoCapture:)])
                [_delegate recorderDidResumeVideoCapture:self];
        }];
    }];
}

- (void)endVideoCapture
{
    DLog(@"ending video capture");
    
    [self _enqueueBlockOnCaptureVideoQueue:^{
        if (!_flags.recording)
            return;
        
        if (!_mediaWriter) {
            DLog(@"media writer unavailable to end");
            return;
        }
        
        _flags.recording = NO;
        _flags.paused = NO;
        
        void (^finishWritingCompletionHandler)(void) = ^{
            Float64 capturedDuration = self.capturedVideoSeconds;
            
            _timeOffset = kCMTimeInvalid;
            _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
            _flags.interrupted = NO;
            
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(recorderDidEndVideoCapture:)])
                    [_delegate recorderDidEndVideoCapture:self];
                
                NSMutableDictionary *videoDict = [[NSMutableDictionary alloc] init];
                NSString *path = [_mediaWriter.outputURL path];
                if (path) {
                    videoDict[XMVideoRecorderVideoPathKey] = path;
                    
                    if (_flags.thumbnailEnabled) {
                        [self captureVideoThumbnailAtTime:capturedDuration];
                        [self _generateThumbnailsForVideoWithURL:_mediaWriter.outputURL inDictionary:videoDict];
                    }
                }
                
                videoDict[XMVideoRecorderVideoCapturedDurationKey] = @(capturedDuration);
                
                NSError *error = [_mediaWriter error];
                if ([_delegate respondsToSelector:@selector(recorder:capturedVideo:error:)]) {
                    [_delegate recorder:self capturedVideo:videoDict error:error];
                }
            }];
        };
        [_mediaWriter finishWritingWithCompletionHandler:finishWritingCompletionHandler];
    }];
}

- (void)cancelVideoCapture
{
    DLog(@"cancel video capture");
    
    [self _enqueueBlockOnCaptureVideoQueue:^{
        _flags.recording = NO;
        _flags.paused = NO;
        
        [_captureThumbnailTimes removeAllObjects];
        [_captureThumbnailFrames removeAllObjects];
        
        void (^finishWritingCompletionHandler)(void) = ^{
            _timeOffset = kCMTimeInvalid;
            _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
            _flags.interrupted = NO;
            
            [self _enqueueBlockOnMainQueue:^{
                NSError *error = [NSError errorWithDomain:XMVideoRecorderErrorDomain code:XMVideoRecorderErrorCancelled userInfo:nil];
                if ([_delegate respondsToSelector:@selector(recorder:capturedVideo:error:)]) {
                    [_delegate recorder:self capturedVideo:nil error:error];
                }
            }];
        };
        
        [_mediaWriter finishWritingWithCompletionHandler:finishWritingCompletionHandler];
    }];
}

- (void)_automaticallyEndCaptureIfMaximumDurationReachedWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMTime currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (!_flags.interrupted && CMTIME_IS_VALID(currentTimestamp) && CMTIME_IS_VALID(_startTimestamp) && CMTIME_IS_VALID(_maximumCaptureDuration)) {
        if (CMTIME_IS_VALID(_timeOffset)) {
            // Current time stamp is actually timstamp with data from globalClock
            // In case, if we had interruption, then _timeOffset
            // will have information about the time diff between globalClock and assetWriterClock
            // So in case if we had interruption we need to remove that offset from "currentTimestamp"
            currentTimestamp = CMTimeSubtract(currentTimestamp, _timeOffset);
        }
        CMTime currentCaptureDuration = CMTimeSubtract(currentTimestamp, _startTimestamp);
        if (CMTIME_IS_VALID(currentCaptureDuration)) {
            if (CMTIME_COMPARE_INLINE(currentCaptureDuration, >=, _maximumCaptureDuration)) {
                [self _enqueueBlockOnMainQueue:^{
                    [self endVideoCapture];
                }];
            }
        }
    }
}

- (void)_failVideoCaptureWithErrorCode:(NSInteger)errorCode
{
    if (errorCode && [_delegate respondsToSelector:@selector(recorder:capturedVideo:error:)]) {
        NSError *error = [NSError errorWithDomain:XMVideoRecorderErrorDomain code:errorCode userInfo:nil];
        [_delegate recorder:self capturedVideo:nil error:error];
    }
}

#pragma mark - media writer setup

- (BOOL)_setupMediaWriterAudioInputWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    NSDictionary *audioCompressionSettings = [_captureOutputAudio recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeMPEG4];
    
    return [_mediaWriter setupAudioWithSettings:audioCompressionSettings];
}

- (BOOL)_setupMediaWriterVideoInputWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    
    CMVideoDimensions videoDimensions = dimensions;
    switch (_outputFormat) {
        case XMOutputFormatSquare:
        {
            int32_t min = MIN(dimensions.width, dimensions.height);
            videoDimensions.width = min;
            videoDimensions.height = min;
            break;
        }
        case XMOutputFormatWidescreen:
        {
            videoDimensions.width = dimensions.width;
            videoDimensions.height = (int32_t)(dimensions.width * 9 / 16.0f);
            break;
        }
        case XMOutputFormatStandard:
        {
            videoDimensions.width = dimensions.width;
            videoDimensions.height = (int32_t)(dimensions.width * 3 / 4.0f);
            break;
        }
        case XMOutputFormatPreset:
        default:
            break;
    }
    
    NSDictionary *compressionSettings = nil;
    
    if (_additionalCompressionProperties && [_additionalCompressionProperties count] > 0) {
        NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionaryWithDictionary:_additionalCompressionProperties];
        mutableDictionary[AVVideoAverageBitRateKey] = @(_videoBitRate);
        mutableDictionary[AVVideoMaxKeyFrameIntervalKey] = @(_videoFrameRate);
        compressionSettings = mutableDictionary;
    } else {
        compressionSettings = @{ AVVideoAverageBitRateKey : @(_videoBitRate),
                                 AVVideoMaxKeyFrameIntervalKey : @(_videoFrameRate) };
    }
    
    NSDictionary *videoSettings = @{ AVVideoCodecKey : AVVideoCodecH264,
                                     AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
                                     AVVideoWidthKey : @(videoDimensions.width),
                                     AVVideoHeightKey : @(videoDimensions.height),
                                     AVVideoCompressionPropertiesKey : compressionSettings };
    
    
    return [_mediaWriter setupVideoWithSettings:videoSettings withAdditional:[self additionalVideoProperties]];
}

#pragma mark - captureFrameAsPhoto
- (void)captureVideoFrameAsPhoto
{
    _flags.videoCaptureFrame = YES;
}

- (void)captureCurrentVideoThumbnail
{
    if (_flags.recording) {
        [self captureVideoThumbnailAtTime:self.capturedVideoSeconds];
    }
}

- (void)captureVideoThumbnailAtTime:(Float64)seconds
{
    [_captureThumbnailTimes addObject:@(seconds)];
}

- (void)captureVideoThumbnailAtFrame:(int64_t)frame
{
    [_captureThumbnailFrames addObject:@(frame)];
}

- (void)_generateThumbnailsForVideoWithURL:(NSURL*)url inDictionary:(NSMutableDictionary*)videoDict
{
    if (_captureThumbnailFrames.count == 0 && _captureThumbnailTimes == 0)
        return;
    
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    AVAssetImageGenerator *generate = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generate.appliesPreferredTrackTransform = YES;
    
    int32_t timescale = [@([self videoFrameRate]) intValue];
    
    for (NSNumber *frameNumber in [_captureThumbnailFrames allObjects]) {
        CMTime time = CMTimeMake([frameNumber longLongValue], timescale);
        Float64 timeInSeconds = CMTimeGetSeconds(time);
        [self captureVideoThumbnailAtTime:timeInSeconds];
    }
    
    NSMutableArray *captureTimes = [NSMutableArray array];
    NSArray *thumbnailTimes = [_captureThumbnailTimes allObjects];
    NSArray *sortedThumbnailTimes = [thumbnailTimes sortedArrayUsingSelector:@selector(compare:)];
    
    
    for (NSNumber *seconds in sortedThumbnailTimes) {
        CMTime time = CMTimeMakeWithSeconds([seconds doubleValue], timescale);
        [captureTimes addObject:[NSValue valueWithCMTime:time]];
    }
    
    NSMutableArray *thumbnails = [NSMutableArray array];
    
    for (NSValue *time in captureTimes) {
        CGImageRef imgRef = [generate copyCGImageAtTime:[time CMTimeValue] actualTime:NULL error:NULL];
        if (imgRef) {
            UIImage *image = [[UIImage alloc] initWithCGImage:imgRef];
            if (image) {
                [thumbnails addObject:image];
            }
            
            CGImageRelease(imgRef);
        }
    }
    
    UIImage *defaultThumbnail = [thumbnails firstObject];
    if (defaultThumbnail) {
        [videoDict setObject:defaultThumbnail forKey:XMVideoRecorderVideoThumbnailKey];
    }
    
    if (thumbnails.count) {
        [videoDict setObject:thumbnails forKey:XMVideoRecorderVideoThumbnailArrayKey];
    }
}

- (void)_capturePhotoFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer) {
        return;
    }
    DLog(@"capturing photo from pixel buffer");
    
    // create associated data
    NSMutableDictionary *photoDict = [[NSMutableDictionary alloc] init];
    NSError *error = nil;
    
    if (!_ciContext) {
        _ciContext = [CIContext contextWithEAGLContext:[[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2]];
    }
    
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:CGRectMake(0, 0, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))];
    
    // add UIImage
    UIImage *uiImage = [UIImage imageWithCGImage:cgImage];
    
    if (cgImage) {
        CFRelease(cgImage);
    }
    
    if (uiImage) {
        if (_outputFormat == XMOutputFormatSquare) {
            uiImage = [self _squareImageWithImage:uiImage scaledToSize:uiImage.size];
        }
        // XMOutputFormatWidescreen
        // XMOutputFormatStandard
        
        photoDict[XMVideoRecorderPhotoImageKey] = uiImage;
        
        // add JPEG, thumbnail
        NSData *jpegData = UIImageJPEGRepresentation(uiImage, 0);
        if (jpegData) {
            // add JPEG
            photoDict[XMVideoRecorderPhotoJPEGKey] = jpegData;
            
            // add thumbnail
            if (_flags.thumbnailEnabled) {
                UIImage *thumbnail = [self _thumbnailJPEGData:jpegData];
                if (thumbnail) {
                    photoDict[XMVideoRecorderPhotoThumbnailKey] = thumbnail;
                }
            }
        }
    } else {
        DLog(@"failed to create image from JPEG");
        error = [NSError errorWithDomain:XMVideoRecorderErrorDomain code:XMVideoRecorderErrorCaptureFailed userInfo:nil];
    }
    
    [self _enqueueBlockOnMainQueue:^{
        if ([_delegate respondsToSelector:@selector(recorder:capturedPhoto:error:)]) {
            [_delegate recorder:self capturedPhoto:photoDict error:error];
        }
    }];
}

- (UIImage *)_thumbnailJPEGData:(NSData *)jpegData
{
    CGImageRef thumbnailCGImage = NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)jpegData);
    
    if (provider) {
        CGImageSourceRef imageSource = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (imageSource) {
            if (CGImageSourceGetCount(imageSource) > 0) {
                NSMutableDictionary *options = [[NSMutableDictionary alloc] initWithCapacity:3];
                options[(id)kCGImageSourceCreateThumbnailFromImageAlways] = @(YES);
                options[(id)kCGImageSourceThumbnailMaxPixelSize] = @(XMVideoRecorderThumbnailWidth);
                options[(id)kCGImageSourceCreateThumbnailWithTransform] = @(YES);
                thumbnailCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
            }
            CFRelease(imageSource);
        }
        CGDataProviderRelease(provider);
    }
    
    UIImage *thumbnail = nil;
    if (thumbnailCGImage) {
        thumbnail = [[UIImage alloc] initWithCGImage:thumbnailCGImage];
        CGImageRelease(thumbnailCGImage);
    }
    return thumbnail;
}

- (UIImage *)_squareImageWithImage:(UIImage *)image scaledToSize:(CGSize)newSize
{
    CGFloat ratio = 0.0;
    CGFloat delta = 0.0;
    CGPoint offset = CGPointZero;
    
    if (image.size.width > image.size.height) {
        ratio = newSize.width / image.size.width;
        delta = (ratio * image.size.width - ratio * image.size.height);
        offset = CGPointMake(delta * 0.5f, 0);
    } else {
        ratio = newSize.width / image.size.height;
        delta = (ratio * image.size.height - ratio * image.size.width);
        offset = CGPointMake(0, delta * 0.5f);
    }
    
    CGRect clipRect = CGRectMake(-offset.x, -offset.y,
                                 (ratio * image.size.width) + delta,
                                 (ratio * image.size.height) + delta);
    
    CGSize squareSize = CGSizeMake(newSize.width, newSize.width);
    
    UIGraphicsBeginImageContextWithOptions(squareSize, YES, 0.0);
    UIRectClip(clipRect);
    [image drawInRect:clipRect];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return newImage;
}

- (void)_failPhotoCaptureWithErrorCode:(NSInteger)errorCode
{
    if (errorCode && [_delegate respondsToSelector:@selector(recorder:capturedPhoto:error:)]) {
        NSError *error = [NSError errorWithDomain:XMVideoRecorderErrorDomain code:errorCode userInfo:nil];
        [_delegate recorder:self capturedPhoto:nil error:error];
    }
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate
- (CMSampleBufferRef)_createSampleBufferWithPixelBuffer:(CVPixelBufferRef)pixelBuffer presentationTime:(CMTime)presentationTime
{
    CMSampleBufferRef sampleBuffer = NULL;
    
    CMSampleTimingInfo timingInfo = {0,};
    timingInfo.duration = kCMTimeInvalid;
    timingInfo.decodeTimeStamp = kCMTimeInvalid;
    timingInfo.presentationTimeStamp = presentationTime;
    
    CMVideoFormatDescriptionRef videoTrackSourceFormatDescription;
    OSStatus err1 = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoTrackSourceFormatDescription);
    if (err1) {
        NSString *exceptionReason = [NSString stringWithFormat:@"CMVideoFormatDescription create failed (%i)", (int)err1];
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:exceptionReason userInfo:nil];
        return NULL;
    }
    
    OSStatus err = CMSampleBufferCreateForImageBuffer( kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoTrackSourceFormatDescription, &timingInfo, &sampleBuffer );
    CFRelease(videoTrackSourceFormatDescription);
    if ( sampleBuffer ) {
        return sampleBuffer;
    }
    else {
        NSString *exceptionReason = [NSString stringWithFormat:@"sample buffer create failed (%i)", (int)err];
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:exceptionReason userInfo:nil];
        return NULL;
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    CFRetain(sampleBuffer);
    
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        DLog(@"sample buffer data is not ready");
        CFRelease(sampleBuffer);
        return;
    }
    
    CVPixelBufferRef renderedPixelBuffer = NULL;
    if (captureOutput == _captureOutputVideo && _flags.previewRunning) {
        
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
        if ([_delegate respondsToSelector:@selector(recorderWillRenderAndWritePixelBuffer:)]) {
            renderedPixelBuffer = [_delegate recorderWillRenderAndWritePixelBuffer:pixelBuffer];
        }
        if (renderedPixelBuffer == NULL) {
            renderedPixelBuffer = pixelBuffer;
            CFRetain(renderedPixelBuffer);
        }
        
        // Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
        self.currentPreviewPixelBuffer = renderedPixelBuffer;
        [self _enqueueBlockOnMainQueue:^{
            @autoreleasepool
            {
                CVPixelBufferRef currentPreviewPixelBuffer = NULL;
                @synchronized( self )
                {
                    currentPreviewPixelBuffer = self.currentPreviewPixelBuffer;
                    if ( currentPreviewPixelBuffer ) {
                        CFRetain( currentPreviewPixelBuffer );
                        self.currentPreviewPixelBuffer = NULL;
                    }
                }
                
                if ( currentPreviewPixelBuffer ) {
                    if (!isInbackground) {
                        [_preview displayPixelBuffer:currentPreviewPixelBuffer];
                    }
                    CFRelease( currentPreviewPixelBuffer );
                }
            }
        }];
        
        // capturing video photo
        [self _executeBlockOnMainQueue:^{
            
            if (_flags.videoCaptureFrame) {
                if (self.isAdjustingFocus || self.isAdjustingExposure) {
//                    DLog(@"device is adjusting");
                }else{
                    _flags.videoCaptureFrame = NO;
                    DLog(@"will capture photo");
                    if ([_delegate respondsToSelector:@selector(recorderWillCapturePhoto:)]) {
                        [_delegate recorderWillCapturePhoto:self];
                    }
                    [self _capturePhotoFromPixelBuffer:renderedPixelBuffer];
                    if ([_delegate respondsToSelector:@selector(recorderDidCapturePhoto:)]) {
                        [_delegate recorderDidCapturePhoto:self];
                    }
                    DLog(@"did capture photo");
                }
            }
        }];
        
    }
    
    
    if (!_flags.recording || _flags.paused) {
        CFRelease(sampleBuffer);
        if (renderedPixelBuffer != NULL) {
            CFRelease( renderedPixelBuffer );
        }
        return;
    }
    
    if (!_mediaWriter) {
        CFRelease(sampleBuffer);
        if (renderedPixelBuffer != NULL) {
            CFRelease( renderedPixelBuffer );
        }
        return;
    }
    
    // setup media writer
    BOOL isVideo = (captureOutput == _captureOutputVideo);
    if (!isVideo && !_mediaWriter.isAudioReady) {
        [self _setupMediaWriterAudioInputWithSampleBuffer:sampleBuffer];
        DLog(@"ready for audio (%d)", _mediaWriter.isAudioReady);
    }
    if (isVideo && !_mediaWriter.isVideoReady) {
        [self _setupMediaWriterVideoInputWithSampleBuffer:sampleBuffer];
        DLog(@"ready for video (%d)", _mediaWriter.isVideoReady);
    }
    
    BOOL isReadyToRecord = ((!_flags.audioCaptureEnabled || _mediaWriter.isAudioReady) && _mediaWriter.isVideoReady);
    if (!isReadyToRecord) {
        CFRelease(sampleBuffer);
        if (renderedPixelBuffer != NULL) {
            CFRelease( renderedPixelBuffer );
        }
        return;
    }
    
    CMTime currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    // calculate the length of the interruption and store the offsets
    if (_flags.interrupted) {
        if (isVideo) {
            CFRelease(sampleBuffer);
            if (renderedPixelBuffer != NULL) {
                CFRelease( renderedPixelBuffer );
            }
            return;
        }
        
        // calculate the appropriate time offset
        if (CMTIME_IS_VALID(currentTimestamp) && CMTIME_IS_VALID(_mediaWriter.audioTimestamp)) {
            if (CMTIME_IS_VALID(_timeOffset)) {
                currentTimestamp = CMTimeSubtract(currentTimestamp, _timeOffset);
            }
            
            CMTime offset = CMTimeSubtract(currentTimestamp, _mediaWriter.audioTimestamp);
            _timeOffset = CMTIME_IS_INVALID(_timeOffset) ? offset : CMTimeAdd(_timeOffset, offset);
            DLog(@"new calculated offset %f valid (%d)", CMTimeGetSeconds(_timeOffset), CMTIME_IS_VALID(_timeOffset));
        }
        _flags.interrupted = NO;
    }
    
    // adjust the sample buffer if there is a time offset
    CMSampleBufferRef bufferToWrite = NULL;
    if (CMTIME_IS_VALID(_timeOffset)) {
        //CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        bufferToWrite = [XMVideoRecorderUtilities createOffsetSampleBufferWithSampleBuffer:sampleBuffer withTimeOffset:_timeOffset];
        if (!bufferToWrite) {
            DLog(@"error subtracting the timeoffset from the sampleBuffer");
        }
    } else {
        bufferToWrite = sampleBuffer;
        CFRetain(bufferToWrite);
    }
    
    // write the sample buffer
    if (bufferToWrite && !_flags.interrupted) {
        
        if (isVideo) {
            
            CMSampleBufferRef newSampleBuffer = [self _createSampleBufferWithPixelBuffer:renderedPixelBuffer presentationTime:CMSampleBufferGetPresentationTimeStamp(bufferToWrite)];
            CFRelease( renderedPixelBuffer );
            if (newSampleBuffer == NULL) {
                newSampleBuffer = bufferToWrite;
                CFRetain(newSampleBuffer);
            }
            [_mediaWriter writeSampleBuffer:newSampleBuffer withMediaTypeVideo:isVideo];
            
            _flags.videoWritten = YES;
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(recorder:didCaptureVideoSampleBuffer:)]) {
                    [_delegate recorder:self didCaptureVideoSampleBuffer:newSampleBuffer];
                }
            }];
            CFRelease(newSampleBuffer);
            
        } else if (!isVideo && _flags.videoWritten) {
            
            [_mediaWriter writeSampleBuffer:bufferToWrite withMediaTypeVideo:isVideo];
            
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(recorder:didCaptureAudioSample:)]) {
                    [_delegate recorder:self didCaptureAudioSample:bufferToWrite];
                }
            }];
            
        }
        
    }
    
    [self _automaticallyEndCaptureIfMaximumDurationReachedWithSampleBuffer:sampleBuffer];
    
    if (bufferToWrite) {
        CFRelease(bufferToWrite);
    }
    
    CFRelease(sampleBuffer);
    
}

#pragma mark - App NSNotifications

- (void)_applicationWillEnterForeground:(NSNotification *)notification
{
    DLog(@"applicationWillEnterForeground");
    [self _enqueueBlockOnCaptureVideoQueue:^{
        isInbackground = NO;
    }];
    
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if (!_flags.previewRunning)
            return;
        
        [self _enqueueBlockOnMainQueue:^{
            [self startPreview];
        }];
    }];
}

- (void)_applicationDidEnterBackground:(NSNotification *)notification
{
    DLog(@"applicationDidEnterBackground");
    [self _enqueueBlockOnCaptureVideoQueue:^{
        isInbackground = YES;
    }];
    
    [self _enqueueBlockOnMainQueue:^{
        [_preview reset];
    }];
    
    if (_flags.recording)
        [self pauseVideoCapture];
    
    if (_flags.previewRunning) {
        [self stopPreview];
        [self _enqueueBlockOnCaptureSessionQueue:^{
            _flags.previewRunning = YES;
        }];
    }
}

#pragma mark - AV NSNotifications

// capture session handlers

- (void)_sessionRuntimeErrored:(NSNotification *)notification
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if ([notification object] == _captureSession) {
            NSError *error = [[notification userInfo] objectForKey:AVCaptureSessionErrorKey];
            if (error) {
                switch ([error code]) {
                    case AVErrorMediaServicesWereReset:
                    {
                        DLog(@"error media services were reset");
                        [self _destroyCamera];
                        if (_flags.previewRunning)
                            [self startPreview];
                        break;
                    }
                    case AVErrorDeviceIsNotAvailableInBackground:
                    {
                        DLog(@"error media services not available in background");
                        break;
                    }
                    default:
                    {
                        DLog(@"error media services failed, error (%@)", error);
                        [self _destroyCamera];
                        if (_flags.previewRunning)
                            [self startPreview];
                        break;
                    }
                }
            }
        }
    }];
}

- (void)_sessionStarted:(NSNotification *)notification
{
    [self _enqueueBlockOnMainQueue:^{
        if ([notification object] != _captureSession)
            return;
        
        DLog(@"session was started");
        
        // ensure there is a capture device setup
        if (_currentInput) {
            AVCaptureDevice *device = [_currentInput device];
            if (device) {
                [self willChangeValueForKey:@"currentDevice"];
                [self _setCurrentDevice:device];
                [self didChangeValueForKey:@"currentDevice"];
            }
        }
        
        if ([_delegate respondsToSelector:@selector(recorderSessionDidStart:)]) {
            [_delegate recorderSessionDidStart:self];
        }
    }];
}

- (void)_sessionStopped:(NSNotification *)notification
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if ([notification object] != _captureSession)
            return;
        
        DLog(@"session was stopped");
        
        if (_flags.recording)
            [self endVideoCapture];
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderSessionDidStop:)]) {
                [_delegate recorderSessionDidStop:self];
            }
        }];
    }];
}

- (void)_sessionWasInterrupted:(NSNotification *)notification
{
    [self _enqueueBlockOnMainQueue:^{
        if ([notification object] != _captureSession)
            return;
        
        DLog(@"session was interrupted");
        
        if (_flags.recording) {
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(recorderSessionDidStop:)]) {
                    [_delegate recorderSessionDidStop:self];
                }
            }];
        }
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderSessionWasInterrupted:)]) {
                [_delegate recorderSessionWasInterrupted:self];
            }
        }];
    }];
}

- (void)_sessionInterruptionEnded:(NSNotification *)notification
{
    [self _enqueueBlockOnMainQueue:^{
        
        if ([notification object] != _captureSession)
            return;
        
        DLog(@"session interruption ended");
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderSessionInterruptionEnded:)]) {
                [_delegate recorderSessionInterruptionEnded:self];
            }
        }];
        
    }];
}

// capture input handler

- (void)_inputPortFormatDescriptionDidChange:(NSNotification *)notification
{
    // when the input format changes, store the clean aperture
    // (clean aperture is the rect that represents the valid image data for this display)
    AVCaptureInputPort *inputPort = (AVCaptureInputPort *)[notification object];
    if (inputPort) {
        CMFormatDescriptionRef formatDescription = [inputPort formatDescription];
        if (formatDescription) {
            _cleanAperture = CMVideoFormatDescriptionGetCleanAperture(formatDescription, YES);
            if ([_delegate respondsToSelector:@selector(recorder:didChangeCleanAperture:)]) {
                [_delegate recorder:self didChangeCleanAperture:_cleanAperture];
            }
        }
    }
}

// capture device handler

- (void)_deviceSubjectAreaDidChange:(NSNotification *)notification
{
    [self adjustFocusExposureAndWhiteBalance];
}


#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( context == (__bridge void *)XMVideoRecorderFocusObserverContext ) {
        
        BOOL isFocusing = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isFocusing) {
            [self _focusStarted];
        } else {
            [self _focusEnded];
        }
        
    }
    else if ( context == (__bridge void *)XMVideoRecorderExposureObserverContext ) {
        
        BOOL isChangingExposure = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isChangingExposure) {
            [self _exposureChangeStarted];
        } else {
            [self _exposureChangeEnded];
        }
        
    }
    else if ( context == (__bridge void *)XMVideoRecorderWhiteBalanceObserverContext ) {
        
        BOOL isWhiteBalanceChanging = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isWhiteBalanceChanging) {
            [self _whiteBalanceChangeStarted];
        } else {
            [self _whiteBalanceChangeEnded];
        }
        
    }
    else if (context == (__bridge void *)XMVideoRecorderTorchAvailabilityObserverContext ) {
        
        //        DLog(@"torch availability did change");
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderDidChangeTorchAvailablility:)])
                [_delegate recorderDidChangeTorchAvailablility:self];
        }];
        
    }
    else if (context == (__bridge void *)XMVideoRecorderTorchModeObserverContext ) {
        
        //        DLog(@"torch mode did change");
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(recorderDidChangeTorchMode:)])
                [_delegate recorderDidChangeTorchMode:self];
        }];
        
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


@end
