# XMVideoRecorder
`XMVideoRecorder` is an iOS camera engine library allows preview the process of the pixelBuffer from camera in real time and generate video with the pixelBuffer processed. What you see is what you get.
# Features
- [x] zoom support
- [x] capture frame as photo
- [x] customizable UI and user interactions
- [x] torch support
- [x] white balance, focus, and exposure adjustment support
- [x] mirroring support

The sample project provides a way to deal with pixelBuffer from camera. You can use other ways except CoreImage, such as CPU-based, OpenGL, and OpenCV.
# Installation

## CocoaPods

`XMVideoRecorder` is available and recommended for installation using the Cocoa dependency manager [CocoaPods](https://cocoapods.org/). 

To integrate, just add the following line to your `Podfile`:

```ruby
pod 'XMVideoRecorder'
```

## Usage

Import the header.

```objective-c
#import "XMVideoRecorder.h"
```

Setup the camera preview using `[[XMVideoRecorder sharedInstance] preview]`.

```objective-c
    // preview 
    preview = [[XMVideoRecorder sharedInstance] preview];
    preview.frame = self.view.bounds;
    [self.view addSubview:preview];
```

Setup and configure the `XMVideoRecorder` controller, then start the camera preview.

```objective-c
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
}
```

Start/pause/resume recording.

```objective-c
    [[XMVideoRecorder sharedInstance] startVideoCapture];
    [[XMVideoRecorder sharedInstance] pauseVideoCapture];
    [[XMVideoRecorder sharedInstance] resumeVideoCapture];
```

End recording.

```objective-c
    [[XMVideoRecorder sharedInstance] endVideoCapture];
```

Handle the final video output or error accordingly.

```objective-c
- (void)recorder:(XMVideoRecorder *)recorder capturedVideo:(NSDictionary *)videoDict error:(NSError *)error
{
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
```

# License

XMVideoRecorder is available under the MIT license, see the License file for more information.
