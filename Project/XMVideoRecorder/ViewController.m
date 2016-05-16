//
//  ViewController.m
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/28.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import "ViewController.h"
#import "XMVideoRecorder.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import "XMVideoRecorderUtilities.h"
#import "RenderUtilities.h"

@interface ViewController ()<XMVideoRecorderDelegate>{
    XMVideoRecorderPreview *preview;
    UIView *swithView;
    UIButton *capturePhotoButton;
    UIButton *recordButton;
    UIButton *flipButton;
    UIButton *torchButton;
    UIImageView *focusImageView;
    ZoomIndicatorView *zoomIndicatorView;
    UILabel *timeLabel;
    NSTimer *timer;//录制进行中
    CGFloat currentTime;//当前已录制时间
    CGFloat preZoomFactor;
    RenderUtilities *renderUtilities;
}

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    preZoomFactor = 1;
    renderUtilities = [[RenderUtilities alloc] init];
    
    [self initXMVideoRecorder];
    [self initViews];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[XMVideoRecorder sharedInstance] startPreview];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [[XMVideoRecorder sharedInstance] stopPreview];
}

- (void)initViews
{
    self.view.backgroundColor = [UIColor blackColor];
    
    preview = [[XMVideoRecorder sharedInstance] preview];
    preview.frame = self.view.bounds;
    [self.view addSubview:preview];
    
    focusImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"FocusCamera"]];
    focusImageView.alpha = 0.0f;
    [preview addSubview:focusImageView];
    
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusAction:)];
    [preview addGestureRecognizer:tapGesture];
    
    UIPinchGestureRecognizer *pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(zoomAction:)];
    [preview addGestureRecognizer:pinchGesture];
    
    swithView = [[UIView alloc] initWithFrame:preview.frame];
    swithView.backgroundColor = [UIColor blackColor];
    swithView.hidden = YES;
    [preview addSubview:swithView];
    
    UIView *topView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.frame), 44)];
    topView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    [self.view addSubview:topView];
    
    flipButton = [UIButton buttonWithType:UIButtonTypeCustom];
    flipButton.frame = CGRectMake(CGRectGetWidth(topView.frame)-44, 0, 44, 44);
    [flipButton setImage:[UIImage imageNamed:@"FilpCamera"] forState:UIControlStateNormal];
    [flipButton addTarget:self action:@selector(flipCamera:) forControlEvents:UIControlEventTouchUpInside];
    [topView addSubview:flipButton];
    
    timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(44, 0, topView.frame.size.width-44*2, 44)];
    timeLabel.textAlignment = NSTextAlignmentCenter;
    timeLabel.backgroundColor = [UIColor clearColor];
    timeLabel.textColor = [UIColor whiteColor];
    timeLabel.font = [UIFont systemFontOfSize:17];
    timeLabel.text = @"00:00:00";
    [topView addSubview:timeLabel];
    
    torchButton = [UIButton buttonWithType:UIButtonTypeCustom];
    torchButton.frame = CGRectMake(0, 0, 44, 44);
    [torchButton setImage:[UIImage imageNamed:@"TorchClose"] forState:UIControlStateNormal];
    [torchButton addTarget:self action:@selector(switchTorch:) forControlEvents:UIControlEventTouchUpInside];
    [topView addSubview:torchButton];
    
    UIView *bottomView = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.frame.size.height-100, CGRectGetWidth(self.view.frame), 100)];
    bottomView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    [self.view addSubview:bottomView];
    
    zoomIndicatorView = [[ZoomIndicatorView alloc] initWithFrame:CGRectMake(10, self.view.frame.size.height -100-10-5, CGRectGetWidth(self.view.frame)-10*2, 5)];
    zoomIndicatorView.alpha = 0.0f;
    [self.view addSubview:zoomIndicatorView];
    
    recordButton = [UIButton buttonWithType:UIButtonTypeCustom];
    recordButton.frame = CGRectMake(bottomView.frame.size.width/2.0f-83/2.0f, bottomView.frame.size.height/2.0f-83/2.0f, 83, 83);
    [recordButton setImage:[UIImage imageNamed:@"StartRecorder"] forState:UIControlStateNormal];
    [recordButton setImage:[UIImage imageNamed:@"StopRecorder"] forState:UIControlStateSelected];
    [recordButton setImage:[UIImage imageNamed:@"CantRecorder"] forState:UIControlStateDisabled];
    [recordButton addTarget:self action:@selector(recordAction:) forControlEvents:UIControlEventTouchUpInside];
    recordButton.enabled = NO;
    [bottomView addSubview:recordButton];
    
    capturePhotoButton = [UIButton buttonWithType:UIButtonTypeCustom];
    capturePhotoButton.frame = CGRectMake((CGRectGetWidth(bottomView.frame)/2.0f-83/2.0f)/2.0f-44/2.0f, bottomView.frame.size.height/2.0f-44/2.0f, 44, 44);
    [capturePhotoButton setTitle:@"截图" forState:UIControlStateNormal];
    [capturePhotoButton addTarget:self action:@selector(captureFrameAsPhoto:) forControlEvents:UIControlEventTouchUpInside];
    [bottomView addSubview:capturePhotoButton];
}

- (void)initXMVideoRecorder
{
    XMVideoRecorder *videoRecorder = [XMVideoRecorder sharedInstance];
    videoRecorder.delegate = self;
    videoRecorder.cameraDevice = XMCameraDeviceBack;
    videoRecorder.cameraOrientation = XMCameraOrientationPortrait;
    videoRecorder.outputFormat = XMOutputFormatPreset;
    videoRecorder.captureDirectory = NSTemporaryDirectory();
    videoRecorder.captureSessionPreset = AVCaptureSessionPreset640x480;
    videoRecorder.videoBitRate = XMVideoBitRate640x480;
    videoRecorder.additionalCompressionProperties = @{AVVideoProfileLevelKey : AVVideoProfileLevelH264Baseline30};
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

#pragma mark - timer

- (void)initTimer
{
    if(timer==nil){
        timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(updateTimeLabel) userInfo:nil repeats:YES];
    }
}

- (void)unInitTimer
{
    if(timer!=nil){
        [timer invalidate];
        timer = nil;
    }
}

- (void)updateTimeLabel
{
    currentTime += 0.1;
    timeLabel.text = [XMVideoRecorderUtilities GetVideoLengthStringFromSeconds:currentTime];
}

#pragma mark - action

- (void)switchTorch:(UIButton *)sender
{
    XMVideoRecorder *recorder = [XMVideoRecorder sharedInstance];
    XMTorchMode newTorchMode = XMTorchModeOff;
    switch (recorder.torchMode) {
        case XMTorchModeOff:
            newTorchMode = XMTorchModeAuto;
            [torchButton setImage:[UIImage imageNamed:@"TorchAuto"] forState:UIControlStateNormal];
            break;
        case XMTorchModeAuto:
            newTorchMode = XMTorchModeOn;
            [torchButton setImage:[UIImage imageNamed:@"TorchOpen"] forState:UIControlStateNormal];
            break;
        case XMTorchModeOn:
            newTorchMode = XMTorchModeOff;
            [torchButton setImage:[UIImage imageNamed:@"TorchClose"] forState:UIControlStateNormal];
            break;
        default:
            break;
    }
    recorder.torchMode = newTorchMode;
}

- (void)flipCamera:(UIButton *)sender
{
    XMVideoRecorder *recorder = [XMVideoRecorder sharedInstance];
    recorder.cameraDevice = recorder.cameraDevice == XMCameraDeviceBack ? XMCameraDeviceFront : XMCameraDeviceBack;
}

- (void)zoomAction:(UIPinchGestureRecognizer *)pinchGesture
{
    CGFloat zoomFactor = preZoomFactor * pinchGesture.scale;
    if (zoomFactor > [XMVideoRecorder sharedInstance].maxZoomFactor) {
        zoomFactor = [XMVideoRecorder sharedInstance].maxZoomFactor;
    }else if (zoomFactor < [XMVideoRecorder sharedInstance].minZoomFactor){
        zoomFactor = [XMVideoRecorder sharedInstance].minZoomFactor;
    }
    
    if (zoomIndicatorView.alpha == 0) {
        zoomIndicatorView.alpha = 1.0f;
    }
    [zoomIndicatorView setProgress:(zoomFactor-1)/([XMVideoRecorder sharedInstance].maxZoomFactor-1)];
    
    [[XMVideoRecorder sharedInstance] setVideoZoomFactor:zoomFactor withRate:pinchGesture.velocity*2];
    
    if ([pinchGesture state] == UIGestureRecognizerStateEnded ||
        [pinchGesture state] == UIGestureRecognizerStateCancelled ||
        [pinchGesture state] == UIGestureRecognizerStateFailed) {
        preZoomFactor = zoomFactor;
        
        [UIView animateWithDuration:1.5 animations:^{
            zoomIndicatorView.alpha = 0.0f;
        }];
    }
}

- (void)focusAction:(UITapGestureRecognizer *)tapGesture
{
    CGPoint tapPoint = [tapGesture locationInView:preview];
    
    CGRect focusFrame = focusImageView.frame;
    focusFrame.origin.x = tapPoint.x - (focusFrame.size.width * 0.5);
    focusFrame.origin.y = tapPoint.y - (focusFrame.size.height * 0.5);
    [focusImageView setFrame:focusFrame];
    
    focusImageView.transform = CGAffineTransformMakeScale(1.8f, 1.8f);
    focusImageView.alpha = 0.0f;
    [UIView animateWithDuration:0.5f delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        focusImageView.transform = CGAffineTransformIdentity;
        focusImageView.alpha = 1.0f;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:1.0f delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            focusImageView.transform = CGAffineTransformMakeScale(1.2f, 1.2f);
        } completion:^(BOOL finished1) {
            focusImageView.alpha = 0.0f;
        }];
    }];
    
    [[XMVideoRecorder sharedInstance] focusExposeAndAdjustWhiteBalanceAtAdjustedPoint:tapPoint];
}

- (void)captureFrameAsPhoto:(UIButton *)sender
{
    [[XMVideoRecorder sharedInstance] captureVideoFrameAsPhoto];
}

- (void)recordAction:(UIButton *)sender
{
    if (sender.selected) {
        recordButton.enabled = NO;
        [[XMVideoRecorder sharedInstance] endVideoCapture];
    }else{
        flipButton.hidden = YES;
        torchButton.hidden = YES;
        [self initTimer];
        [[XMVideoRecorder sharedInstance] startVideoCapture];
    }
    sender.selected = !sender.selected;
}

#pragma mark - alert
- (void)showAlertViewWithMessage:(NSString *)message title:(NSString *)title
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:@"Dismiss"
                                          otherButtonTitles:nil];
    [alert show];
    currentTime = 0.0f;
    timeLabel.text = @"00:00:00";
    recordButton.enabled = YES;
    flipButton.hidden = NO;
    torchButton.hidden = ![XMVideoRecorder sharedInstance].isTorchAvailable;
}

#pragma mark - XMVideoRecorderDelegate
//实时处理视频数据，把处理后的数据传回XMVideoRecorder
- (CVPixelBufferRef)recorderWillRenderAndWritePixelBuffer:(CVPixelBufferRef)orginPixelBuffer
{
    return [renderUtilities progressPixelBuffer:orginPixelBuffer];
}

- (void)recorderSessionDidStart:(XMVideoRecorder *)recorder
{
    recordButton.enabled = YES;
    flipButton.hidden = NO;
    torchButton.hidden = !recorder.isTorchAvailable;
}

- (void)recorderSessionDidStop:(XMVideoRecorder *)recorder
{
    recordButton.enabled = NO;
    flipButton.hidden = YES;
    torchButton.hidden = YES;
}

- (void)recorderCameraDeviceWillChange:(XMVideoRecorder *)recorder
{
    swithView.hidden = NO;
    recordButton.enabled = NO;
    capturePhotoButton.enabled = NO;
    torchButton.hidden = YES;
}

- (void)recorderCameraDeviceDidChange:(XMVideoRecorder *)recorder
{
    swithView.hidden = YES;
    recordButton.enabled = YES;
    capturePhotoButton.enabled = YES;
    torchButton.hidden = !recorder.isTorchAvailable;
}

- (NSString *)recorder:(XMVideoRecorder *)recorder willStartVideoCaptureToFile:(NSString *)fileName
{
    NSTimeInterval currentTimeInterval = [[NSDate date] timeIntervalSince1970];
    NSString *localVideoName=[NSString stringWithFormat:@"XMVideo_%.0f.mp4",currentTimeInterval*1000];
    
    return localVideoName;
}

- (void)recorder:(XMVideoRecorder *)recorder capturedVideo:(NSDictionary *)videoDict error:(NSError *)error
{
    [self unInitTimer];
    
    NSString *videoPath = [videoDict objectForKey:XMVideoRecorderVideoPathKey];
    CGFloat videoDuration = [[videoDict objectForKey:XMVideoRecorderVideoCapturedDurationKey] floatValue];
    NSLog(@"视频路径：%@，视频时长：%f",videoPath,videoDuration);
    
    if (error && [error.domain isEqual:XMVideoRecorderErrorDomain] && error.code == XMVideoRecorderErrorCancelled) {
        NSLog(@"recording session cancelled");
        return;
    } else if (error) {
        NSLog(@"encounted an error in video capture (%@)", error);
        return;
    }
    
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    __weak typeof(self) weakSelf = self;
    [library writeVideoAtPathToSavedPhotosAlbum:[NSURL fileURLWithPath:videoPath]
                                completionBlock:^(NSURL *assetURL, NSError *error){
                                    if (error) {
                                        NSString *mssg = [NSString stringWithFormat:@"Error saving the video to the photo library. %@", error];
                                        [weakSelf showAlertViewWithMessage:mssg title:nil];
                                    }
                                    else {
                                        [weakSelf showAlertViewWithMessage:@"视频保存到相册了" title:@"告诉你一声"];
                                    }
                                }];
}

- (void)recorderWillCapturePhoto:(XMVideoRecorder *)recorder
{
    capturePhotoButton.enabled = NO;
}

- (void)recorderDidCapturePhoto:(XMVideoRecorder *)recorder
{
    capturePhotoButton.enabled = YES;
}

- (void)recorder:(XMVideoRecorder *)recorder capturedPhoto:(nullable NSDictionary *)photoDict error:(nullable NSError *)error
{
    UIImage *image = [photoDict objectForKey:XMVideoRecorderPhotoImageKey];
    
    UIImageWriteToSavedPhotosAlbum(image, self, @selector(image:didFinishSavingWithError:contextInfo:), nil);
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    if (error) {
        NSString *mssg = [NSString stringWithFormat:@"Error saving the photo to the photo library. %@", error];
        [self showAlertViewWithMessage:mssg title:nil];
    }
    else {
        [self showAlertViewWithMessage:@"截图保存到相册了" title:@"告诉你一声"];
    }

}

@end


@interface ZoomIndicatorView()
{
    CGFloat progress;
}
@end

@implementation ZoomIndicatorView

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 5/2.0f;
        self.backgroundColor = [UIColor whiteColor];
    }
    return self;
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef context        = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    {
        CGContextClearRect(context, rect);
        
        CGContextSetRGBFillColor(context, 255/255.0f, 255/255.0f, 255/255.0f, 1.0);
        CGContextFillRect(context, rect);
        
        CGContextSetRGBFillColor(context, 255/255.0f, 200/255.0f, 0/255.0f, 1.0);
        rect.size.width = progress*self.bounds.size.width;
        
        CGContextFillRect(context, rect);
        CGContextStrokePath(context);
        
    }
    CGContextRestoreGState(context);
}

- (void)setProgress:(CGFloat)p
{
    progress = p;
    [self setNeedsDisplay];
}

@end
