//
//  XMVideoRecorderPreview.h
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/4/29.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface XMVideoRecorderPreview : UIView

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)flushPixelBufferCache;
- (void)reset;

@end