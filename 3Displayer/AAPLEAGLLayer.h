/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 
  This CAEAGLLayer subclass demonstrates how to draw a CVPixelBufferRef using OpenGLES and display the timecode associated with that pixel buffer in the top right corner.
  
 */

#include <GLKit/GLKit.h>

@interface AAPLEAGLLayer : CAEAGLLayer
@property CVPixelBufferRef pixelBuffer;
- (id) initWithFrame:(CGRect)frame;
- (void) initDevice:(UIView *) currentView;
- (void) setPixelBuffer:(CVPixelBufferRef)pb withTS:(NSNumber *) timestamp;
- (void) startRendering;
- (void) startDrawSingleFrame;
- (void) cleanRenderQueue;
- (void) resetRenderBuffer;
- (CVPixelBufferRef) takePicture;


/* orientation */


// At this point, it's still recommended to activate either OrientToDevice or TouchToPan, not both
//   it's possible to have them simultaneously, but the effect is confusing and disorienting


/// Activates accelerometer + gyro orientation
@property (nonatomic) BOOL orientToDevice;

/// Enables UIPanGestureRecognizer to affect view orientation
@property (nonatomic) BOOL touchToPan;

/// Enable Panorama display mode
@property (nonatomic) int displayMode;

/// Fixes up-vector during panning. (trade off: no panning past the poles)
//@property (nonatomic) BOOL preventHeadTilt;


/*  projection & touches  */


@property (nonatomic, readonly) NSSet *touches;

@property (nonatomic, readonly) NSInteger numberOfTouches;

/// Field of view in DEGREES
@property (nonatomic) float fieldOfView;

/// Enables UIPinchGestureRecognizer to affect FieldOfView
@property (nonatomic) BOOL pinchToZoom;

/// Dynamic overlay of latitude and longitude intersection lines for all touches
@property (nonatomic) BOOL showTouches;


@end
