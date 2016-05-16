//
//  RenderUtilities.h
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/5/14.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

@interface RenderUtilities : NSObject

- (CVPixelBufferRef)progressPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end
