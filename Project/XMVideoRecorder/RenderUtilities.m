//
//  RenderUtilities.m
//  XMVideoRecorder
//
//  Created by 徐铭 on 16/5/14.
//  Copyright © 2016年 徐铭. All rights reserved.
//

#import "RenderUtilities.h"

#define RETAINED_BUFFER_COUNT 6

@interface RenderUtilities (){
    CIContext *_ciContext;
    CGColorSpaceRef _rgbColorSpace;
    CVPixelBufferPoolRef _bufferPool;
    CFDictionaryRef _bufferPoolAuxAttributes;
    CIFilter *MonoFilter;
}

@end

@implementation RenderUtilities

- (void)dealloc
{
    [self deleteBuffers];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
        EAGLContext *eaglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        _ciContext = [CIContext contextWithEAGLContext:eaglContext options:@{kCIContextWorkingColorSpace : [NSNull null]}];
        MonoFilter = [CIFilter filterWithName:@"CIPhotoEffectMono"];
    }
    return self;
}

- (CVPixelBufferRef)progressPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!_bufferPool) {
        [self initializeBuffersWithPixelBuffer:pixelBuffer];
    }
    
    OSStatus err = noErr;
    CVPixelBufferRef renderedOutputPixelBuffer = NULL;
    
    err = CVPixelBufferPoolCreatePixelBuffer( kCFAllocatorDefault, _bufferPool, &renderedOutputPixelBuffer );
    if ( err ) {
        NSLog(@"Cannot obtain a pixel buffer from the buffer pool (%d)", (int)err );
        return NULL;
    }
    
    CIImage *inputCIImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    [MonoFilter setValue:inputCIImage forKeyPath:@"inputImage"];
    CIImage *outputCIImage = [MonoFilter outputImage];
    
    // render the filtered image out to a pixel buffer (no locking needed as CIContext's render method will do that)
    [_ciContext render:outputCIImage toCVPixelBuffer:renderedOutputPixelBuffer bounds:[outputCIImage extent] colorSpace:_rgbColorSpace];
    
    return renderedOutputPixelBuffer;
}

- (BOOL)initializeBuffersWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    BOOL success = YES;
    
    _bufferPool = createPixelBufferPool((int32_t)CVPixelBufferGetWidth(pixelBuffer), (int32_t)CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetPixelFormatType(pixelBuffer), RETAINED_BUFFER_COUNT);
    if ( ! _bufferPool ) {
        NSLog( @"Problem initializing a buffer pool." );
        success = NO;
        goto bail;
    }
    
    _bufferPoolAuxAttributes = createPixelBufferPoolAuxAttributes(RETAINED_BUFFER_COUNT);
    preallocatePixelBuffersInPool( _bufferPool, _bufferPoolAuxAttributes );
    
bail:
    if ( ! success ) {
        [self deleteBuffers];
    }
    return success;
}

- (void)deleteBuffers
{
    if ( _bufferPool ) {
        CFRelease( _bufferPool );
    }
    if ( _bufferPoolAuxAttributes ) {
        CFRelease( _bufferPoolAuxAttributes );
        _bufferPoolAuxAttributes = NULL;
    }
    if ( _ciContext ) {
        _ciContext = nil;
    }
    if ( _rgbColorSpace ) {
        CFRelease( _rgbColorSpace );
        _rgbColorSpace = NULL;
    }
}

static CVPixelBufferPoolRef createPixelBufferPool( int32_t width, int32_t height, OSType pixelFormat, int32_t maxBufferCount )
{
    CVPixelBufferPoolRef outputPool = NULL;
    
    NSDictionary *sourcePixelBufferOptions = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
                                                (id)kCVPixelBufferWidthKey : @(width),
                                                (id)kCVPixelBufferHeightKey : @(height),
                                                (id)kCVPixelFormatOpenGLESCompatibility : @(YES),
                                                (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    
    NSDictionary *pixelBufferPoolOptions = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey : @(maxBufferCount) };
    
    CVPixelBufferPoolCreate( kCFAllocatorDefault, (__bridge  CFDictionaryRef)pixelBufferPoolOptions, (__bridge CFDictionaryRef)sourcePixelBufferOptions, &outputPool );
    
    return outputPool;
}

static CFDictionaryRef createPixelBufferPoolAuxAttributes( int32_t maxBufferCount )
{
    // CVPixelBufferPoolCreatePixelBufferWithAuxAttributes() will return kCVReturnWouldExceedAllocationThreshold if we have already vended the max number of buffers
    NSDictionary *auxAttributes = [[NSDictionary alloc] initWithObjectsAndKeys:@(maxBufferCount), (id)kCVPixelBufferPoolAllocationThresholdKey, nil];
    return (CFDictionaryRef)CFBridgingRetain(auxAttributes);
}

static void preallocatePixelBuffersInPool( CVPixelBufferPoolRef pool, CFDictionaryRef auxAttributes )
{
    // Preallocate buffers in the pool, since this is for real-time display/capture
    NSMutableArray *pixelBuffers = [[NSMutableArray alloc] init];
    while ( 1 )
    {
        CVPixelBufferRef pixelBuffer = NULL;
        CVReturn err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes( kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer );
        
        if ( err == kCVReturnWouldExceedAllocationThreshold ) {
            break;
        }
        assert( err == noErr );
        
        [pixelBuffers addObject:(__bridge id)pixelBuffer];
        CFRelease( pixelBuffer );
    }
}

@end
