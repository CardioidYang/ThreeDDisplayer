/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 
 This CAEAGLLayer subclass demonstrates how to draw a CVPixelBufferRef using OpenGLES and display the timecode associated with that pixel buffer in the top right corner.
 
 */

#import "AAPLEAGLLayer.h"

#import <AVFoundation/AVUtilities.h>
#import <OpenGLES/ES1/gl.h>
#include <OpenGLES/ES2/glext.h>
#import <CoreMotion/CoreMotion.h>

#define FPS 60
#define FOV_MIN 1
#define FOV_MAX 155
#define Z_NEAR 0.1f
#define Z_FAR 100.0f

#define SENSOR_ORIENTATION [[UIApplication sharedApplication] statusBarOrientation] //enum  1(NORTH)  2(SOUTH)  3(EAST)  4(WEST)

enum
{
    PLAT_DISPLAY,
    PANORAMIC_DISPLAY_SINGLE,
    PANORAMIC_DISPLAY_DOUBLE
};


// Uniform index.
enum
{
    UNIFORM_Y,
    UNIFORM_UV,
    UNIFORM_COLOR_CONVERSION_MATRIX,
    UNIFORM_MVP_MATRIX,
    UNIFORM_ROTATIOM_MATRIX,
    UNIFORM_ORIENTATION_MATRIX,
    UNIFORM_TRANSFORM_MATRIX,
    UNIFORM_SCALE,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

// Attribute index.
enum
{
    ATTRIB_VERTEX,
    ATTRIB_TEXCOORD,
    NUM_ATTRIBUTES
};

// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)

// BT.601, which is the standard for SDTV.
static const GLfloat kColorConversion601[] = {
    1.164,  1.164, 1.164,
    0.0, -0.392, 2.017,
    1.596, -0.813,   0.0,
};

// BT.709, which is the standard for HDTV.
static const GLfloat kColorConversion709[] = {
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
};

// this really should be included in GLKit
GLKQuaternion GLKQuaternionFromTwoVectors(GLKVector3 u, GLKVector3 v){
    GLKVector3 w = GLKVector3CrossProduct(u, v);
    
    GLKQuaternion q = GLKQuaternionMake(w.x, w.y, w.z, GLKVector3DotProduct(u, v));
    q.w += GLKQuaternionLength(q);
    return GLKQuaternionNormalize(q);
}

@interface Sphere : NSObject

-(GLfloat*) getVertexData;
-(GLfloat*) getTextureData;
-(GLfloat*) getNormalData;
-(GLint) getArrayCount;
-(id) init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile;

@end

@interface VideoQueueData : NSObject

@property NSNumber *timestamp;
@property CVPixelBufferRef videoData;

@end

@implementation VideoQueueData

@end

@interface NSMutableArray (QueueAdditions)

- (id) dequeue;
- (void) enqueue:(id)obj;
@end

NSLock *_frameBufferQueueLock;
@implementation NSMutableArray (QueueAdditions)
// Queues are first-in-first-out, so we remove objects from the head
- (id) dequeue {
    [_frameBufferQueueLock lock];
    // if ([self count] == 0) return nil; // to avoid raising exception (Quinn)
    id headObject = [self objectAtIndex:0];
    if (headObject != nil) {
        //[[headObject retain] autorelease]; // so it isn't dealloc'ed on remove
        [self removeObjectAtIndex:0];
    }
    [_frameBufferQueueLock unlock];
    return headObject;
}

// Add to the tail of the queue (no one likes it when people cut in line!)
- (void) enqueue:(id)anObject {
    [_frameBufferQueueLock lock];
    [self addObject:anObject];
    [_frameBufferQueueLock unlock];
    //this method automatically adds to the end of the array
}
@end

@interface AAPLEAGLLayer ()
{
    // The pixel dimensions of the CAEAGLLayer.
    GLint _backingWidth;
    GLint _backingHeight;
    
    EAGLContext *_context;
    CVOpenGLESTextureRef _lumaTexture;
    CVOpenGLESTextureRef _chromaTexture;
    
    GLuint _frameBufferHandle;
    GLuint _colorBufferHandle;
    
    const GLfloat *_preferredConversion;
    
    
    //panorama view
    Sphere *sphere, *meridians;
    CMMotionManager *motionManager;
    UIPinchGestureRecognizer *pinchGesture;
    UIPanGestureRecognizer *panGesture;
    GLKMatrix4 _projectionMatrix, _attitudeMatrix, _offsetMatrix;
    float _aspectRatio;
    
    GLfloat _scale;
    NSMutableArray *_frameBufferQueue;
    
    GLKMatrix4 _cachMotion;
    
    long long _preLastPopDistTS;
    long long _lastPopDistanceTS;
    long long _lastPopActualTS;
    
    BOOL panGestureInit;
}
@property GLuint program;

@end
@implementation AAPLEAGLLayer
@synthesize pixelBuffer = _pixelBuffer;

-(CVPixelBufferRef) pixelBuffer
{
    return _pixelBuffer;
}

- (void) setPixelBuffer:(CVPixelBufferRef)pb withTS:(NSNumber *) timestamp;
{
    CVPixelBufferRef pixelBuffer = CVPixelBufferRetain(pb);
    VideoQueueData * queueData = [[VideoQueueData alloc] init];
    queueData.timestamp=timestamp;
    queueData.videoData=pixelBuffer;
    
    //NSLog(@"add pixelbuffer to queue");
    [_frameBufferQueue enqueue:queueData];
}

- (void) startDrawSingleFrame
{
    if([_frameBufferQueue count]>0) {//dequeue for next rendering
        //NSLog(@"get object from queue %lu", (unsigned long)[_frameBufferQueue count]);
        if(_pixelBuffer) {
            CVPixelBufferRelease(_pixelBuffer);
        }
        VideoQueueData *thisData=(VideoQueueData *)[_frameBufferQueue dequeue];
        _pixelBuffer = thisData.videoData;
    }
    if(_pixelBuffer) {
        //NSLog(@"display buffer");
        int frameWidth = (int)CVPixelBufferGetWidth(_pixelBuffer);
        int frameHeight = (int)CVPixelBufferGetHeight(_pixelBuffer);
        [self displayPixelBuffer:_pixelBuffer width:frameWidth height:frameHeight];
    }
}

- (void) startRendering
{
    if([_frameBufferQueue count]>0) {//dequeue for next rendering
        //NSLog(@"get object from queue %lu", (unsigned long)[_frameBufferQueue count]);
        if(_pixelBuffer) {
            CVPixelBufferRelease(_pixelBuffer);
        }
        //_pixelBuffer = (__bridge CVPixelBufferRef)[_frameBufferQueue dequeue];
        VideoQueueData *thisData=(VideoQueueData *)[_frameBufferQueue dequeue];
        _pixelBuffer = thisData.videoData;
        
        //check time
        long long distDiff = [thisData.timestamp longLongValue] - _lastPopDistanceTS;
        NSTimeInterval timeStamp = [[NSDate date] timeIntervalSince1970];
        // NSTimeInterval is defined as double
        NSNumber *timeStampObj = [NSNumber numberWithDouble: timeStamp];
        long long LocDiff = [timeStampObj doubleValue] *1000 - _lastPopActualTS;
        if (LocDiff < distDiff && _preLastPopDistTS!=0) {
            //NSLog(@"sleep %llu ms", distDiff-LocDiff);
            usleep(1000*(int)(distDiff-LocDiff));
        }
        /*else {
            //NSLog(@"display this frame, distDiff %lld, LocDiff %llu", distDiff, LocDiff);
            //NSLog(@"buffer count %ld", [_frameBufferQueue count]);
        }*/
        
        _preLastPopDistTS = _lastPopDistanceTS;
        _lastPopDistanceTS = [thisData.timestamp longLongValue];
        _lastPopActualTS = [timeStampObj doubleValue] *1000;
        
    }
    if(_pixelBuffer) {
        //NSLog(@"display buffer");
        int frameWidth = (int)CVPixelBufferGetWidth(_pixelBuffer);
        int frameHeight = (int)CVPixelBufferGetHeight(_pixelBuffer);
        [self displayPixelBuffer:_pixelBuffer width:frameWidth height:frameHeight];
    }
}

- (void) cleanRenderQueue
{
    while ([_frameBufferQueue count]>0) {//dequeue for next rendering
        //NSLog(@"get object from queue %lu", (unsigned long)[_frameBufferQueue count]);
        if(_pixelBuffer) {
            CVPixelBufferRelease(_pixelBuffer);
        }
        //_pixelBuffer = (__bridge CVPixelBufferRef)[_frameBufferQueue dequeue];
        VideoQueueData *thisData=(VideoQueueData *)[_frameBufferQueue dequeue];
        _pixelBuffer = thisData.videoData;
    }
}

- (CVPixelBufferRef) takePicture
{
    if(_pixelBuffer) {
        return _pixelBuffer;
    } else {
        return nil;
    }
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super init];
    if (self) {
        CGFloat scale = [[UIScreen mainScreen] scale];
        self.contentsScale = scale;
        
        self.opaque = TRUE;
        self.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking :[NSNumber numberWithBool:YES]};
        
        [self setFrame:frame];
        
        // Set the context into which the frames will be drawn.
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        
        if (!_context) {
            return nil;
        }
        
        // Set the default conversion to BT.709, which is the standard for HDTV.
        _preferredConversion = kColorConversion709;
        
        [self initOpenGL];
        sphere = [[Sphere alloc] init:24 slices:24 radius:1.0 textureFile:nil];
        //meridians = [[Sphere alloc] init:48 slices:48 radius:8.0 textureFile:@"equirectangular-projection-lines.png"];
        _frameBufferQueue=[[NSMutableArray alloc] init];
        _frameBufferQueueLock=[[NSLock alloc] init];
        
        _cachMotion=GLKMatrix4Identity;
        
        _preLastPopDistTS=0;
        _lastPopDistanceTS=0;
        _lastPopActualTS=0;
    }
    
    return self;
}

-(void)setFieldOfView:(float)fieldOfView{
    _fieldOfView = fieldOfView;
    [self rebuildProjectionMatrix];
}

-(void) initDevice:(UIView *) currentView{
    motionManager = [[CMMotionManager alloc] init];
    
    pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchHandler:)];
    [pinchGesture setEnabled:NO];
    [currentView addGestureRecognizer:pinchGesture];
     
    panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panHandlerNew:)];
    [panGesture setMaximumNumberOfTouches:1];
    [panGesture setEnabled:NO];
    [currentView addGestureRecognizer:panGesture];
}

-(void) setTouchToPan:(BOOL)touchToPan{
    panGestureInit=NO;
    _touchToPan = touchToPan;
    [panGesture setEnabled:_touchToPan];
    
    if(touchToPan==NO)
        _offsetMatrix=GLKMatrix4Identity;
}

-(void) setPinchToZoom:(BOOL)pinchToZoom{
    _pinchToZoom = pinchToZoom;
    [pinchGesture setEnabled:_pinchToZoom];
}

-(void) setOrientToDevice:(BOOL)orientToDevice{
    _orientToDevice = orientToDevice;
    if(motionManager.isDeviceMotionAvailable){
        NSLog(@"device motion ready");
        if(_orientToDevice)
            [motionManager startDeviceMotionUpdates];
        else
            [motionManager stopDeviceMotionUpdates];
    } else {
        NSLog(@"device motion is not ready");
    }
    
    if(_orientToDevice==NO) {
        _cachMotion=GLKMatrix4RotateZ(GLKMatrix4Identity, -3.14/2);
    }
}

-(void) setDisplayMode:(int)isPanoramaMode{
    _displayMode=isPanoramaMode;
    
    if(isPanoramaMode==PANORAMIC_DISPLAY_DOUBLE) {
        _aspectRatio = self.frame.size.width/self.frame.size.height/2;
        _fieldOfView = 45 + 45 * atanf(_aspectRatio); // hell ya
        [self rebuildProjectionMatrix];
    } else {
        _aspectRatio = self.frame.size.width/self.frame.size.height;
        _fieldOfView = 45 + 45 * atanf(_aspectRatio); // hell ya
        [self rebuildProjectionMatrix];
    }
}

#pragma mark- ORIENTATION
-(GLKMatrix4) getDeviceOrientationMatrix{
    if([motionManager isDeviceMotionActive]){
        //NSLog(@"ori");
        CMRotationMatrix a = [[[motionManager deviceMotion] attitude] rotationMatrix];
        // arrangements of mappings of sensor axis to virtual axis (columns)
        // and combinations of 90 degree rotations (rows)
        if(SENSOR_ORIENTATION == 4){
            _cachMotion=GLKMatrix4Make( a.m21,-a.m11, a.m31, 0.0f,
                                      a.m23,-a.m13, a.m33, 0.0f,
                                      -a.m22, a.m12,-a.m32, 0.0f,
                                      0.0f , 0.0f , 0.0f , 1.0f);
        }
        if(SENSOR_ORIENTATION == 3){
            _cachMotion=GLKMatrix4Make(-a.m21, a.m11, a.m31, 0.0f,
                                      -a.m23, a.m13, a.m33, 0.0f,
                                      a.m22,-a.m12,-a.m32, 0.0f,
                                      0.0f , 0.0f , 0.0f , 1.0f);
        }
        if(SENSOR_ORIENTATION == 2){
            _cachMotion=GLKMatrix4Make(-a.m11,-a.m21, a.m31, 0.0f,
                                  -a.m13,-a.m23, a.m33, 0.0f,
                                  a.m12, a.m22,-a.m32, 0.0f,
                                  0.0f , 0.0f , 0.0f , 1.0f);
        }
        _cachMotion=GLKMatrix4Make(a.m11, a.m21, a.m31, 0.0f,
                              a.m13, a.m23, a.m33, 0.0f,
                              -a.m12,-a.m22,-a.m32, 0.0f,
                              0.0f , 0.0f , 0.0f , 1.0f);
        return _cachMotion;
    }
    else
        return _cachMotion;
}

-(GLKVector3) vectorFromScreenLocation:(CGPoint)point inAttitude:(GLKMatrix4)matrix{
    GLKMatrix4 inverse = GLKMatrix4Invert(GLKMatrix4Multiply(_projectionMatrix, matrix), nil);
    GLKVector4 screen;
    //vector defined by currently captured orientation
    float xMovement=point.x/self.frame.size.width;
    float yMovement=point.y/self.frame.size.height;
    
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    static UIDeviceOrientation initOrientation;
    
    if(panGestureInit) {
        if(initOrientation == 1 || initOrientation == 2) {
            //NSLog(@"init type 1, 2");
            screen= GLKVector4Make(2.0*(xMovement-.5),
                                   2.0*(.5-yMovement),
                                   1.0, 1.0);
        }
        else if(initOrientation == 3 || initOrientation == 4){ // ==3 or 4
            //NSLog(@"init type 3, 4");
            screen= GLKVector4Make(-8.0*(.5-yMovement),
                                   2.0*(xMovement-.5),
                                   1.0, 1.0);
        }
    } else {
        if(orientation == 1 || orientation == 2) {
            //NSLog(@"type 1, 2");
            screen= GLKVector4Make(2.0*(xMovement-.5),
                                   2.0*(.5-yMovement),
                                   1.0, 1.0);
        }
        else if(orientation == 3 || orientation == 4){ // ==3 or 4
            //NSLog(@"type 3, 4");
            screen= GLKVector4Make(-8.0*(.5-yMovement),
                                   2.0*(xMovement-.5),
                                   1.0, 1.0);
        }
    }
    if(!panGestureInit) {
        initOrientation=orientation;
        panGestureInit=YES;
    }
    
    //    if (SENSOR_ORIENTATION == 3 || SENSOR_ORIENTATION == 4)
    //        screen = GLKVector4Make(2.0*(screenTouch.x/self.frame.size.height-.5),
    //                                2.0*(.5-screenTouch.y/self.frame.size.width),
    //                                1.0, 1.0);
    
    GLKVector4 vec = GLKMatrix4MultiplyVector4(inverse, screen);
    return GLKVector3Normalize(GLKVector3Make(vec.x, vec.y, vec.z));
}

-(GLKVector2) vectorFromScreenLocation2:(CGPoint)point {
    
    float xMove=point.x/self.frame.size.width;
    float yMove=point.y/self.frame.size.height;
    
    GLKVector2 vec=GLKVector2Make(xMove, yMove);
    
    return GLKVector2Make(vec.x, vec.y);
}

-(void)pinchHandler:(UIPinchGestureRecognizer*)sender{
    _numberOfTouches = sender.numberOfTouches;
    static float zoom;
    if([sender state] == 1) {
        //NSLog(@"[sender state] == 1");
        zoom = _fieldOfView;
    }
    if([sender state] == 2){
        
        CGFloat newFOV = zoom / [sender scale];
        
        //NSLog(@"[sender state] == 2 , FOV %.2f",newFOV);
//        if(newFOV < FOV_MIN) newFOV = FOV_MIN;
//        else if(newFOV > FOV_MAX) newFOV = FOV_MAX;
        
        if(newFOV <100 && newFOV > 10) {
            [self setFieldOfView:newFOV];
        }
        
    }
    if([sender state] == 3){
        //NSLog(@"[sender state] == 3");
        _numberOfTouches = 0;
    }
}

-(void) panHandlerOld:(UIPanGestureRecognizer*)sender{
    static GLKVector3 touchVector;
    if([sender state] == 1){
        touchVector = [self vectorFromScreenLocation:[sender locationInView:sender.view] inAttitude:_offsetMatrix];
        //NSLog(@"vector 1 %.2f, %.2f, %.2f",touchVector.x,touchVector.y,touchVector.z);
        
    }
    else if([sender state] == 2){
        GLKVector3 nowVector = [self vectorFromScreenLocation:[sender locationInView:sender.view] inAttitude:_offsetMatrix];
        //NSLog(@"now vec 1 %.2f, %.2f, %.2f",nowVector.x,nowVector.y,nowVector.z);
        
        GLKQuaternion q = GLKQuaternionFromTwoVectors(touchVector, nowVector);
        _offsetMatrix = GLKMatrix4Multiply(_offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
        
        // in progress for preventHeadTilt
        //        GLKMatrix4 mat = GLKMatrix4Multiply(_offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
        //        _offsetMatrix = GLKMatrix4MakeLookAt(0, 0, 0, -mat.m02, -mat.m12, -mat.m22,  0, 1, 0);
        
    }
    else{
        _numberOfTouches = 0;
    }
}

-(void) panHandlerNew:(UIPanGestureRecognizer*)sender{
    //static GLKVector3 touchVector;
    static GLKVector2 touchVector;
    if([sender state] == 1){
        
        touchVector = [self vectorFromScreenLocation2:[sender locationInView:sender.view]];
    }
    else if([sender state] == 2){
        
        GLKVector2 nowVector = [self vectorFromScreenLocation2:[sender locationInView:sender.view]];
        GLKVector2 subVector = GLKVector2Normalize(GLKVector2Subtract(nowVector, touchVector));
        
        float xMovement = subVector.x;
        float yMovement = subVector.y;

        if(xMovement*xMovement>yMovement*yMovement) {
            _offsetMatrix = GLKMatrix4Multiply( GLKMatrix4MakeYRotation(-0.0628 * xMovement), _offsetMatrix);// 3.14/50=0.0628
            //NSLog(@"move x %.2f",xMovement);
        } else {
            _offsetMatrix = GLKMatrix4Multiply( GLKMatrix4MakeXRotation(-0.0628 * yMovement), _offsetMatrix);
            //NSLog(@"move y %.2f",yMovement);
        }
        
    }
    else{
        _numberOfTouches = 0;
    }
}

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer width:(uint32_t)frameWidth height:(uint32_t)frameHeight
{
    
    
    if (!_context || ![EAGLContext setCurrentContext:_context]) {
        return;
    }
    
    if(pixelBuffer == NULL) {
        NSLog(@"Pixel buffer is null");
        return;
    }
    
    CVReturn err;
    
    size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
    
    /*
     Use the color attachment of the pixel buffer to determine the appropriate color conversion matrix.
     */
    CFTypeRef colorAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
    
    if (CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo) {
        _preferredConversion = kColorConversion601;
    }
    else {
        _preferredConversion = kColorConversion709;
    }
    
    /*
     CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture optimally from CVPixelBufferRef.
     */
    
    /*
     Create Y and UV textures from the pixel buffer. These textures will be drawn on the frame buffer Y-plane.
     */
    
    CVOpenGLESTextureCacheRef _videoTextureCache;
    
    // Create CVOpenGLESTextureCacheRef for optimal CVPixelBufferRef to GLES texture conversion.
    err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_videoTextureCache);
    if (err != noErr) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
        return;
    }

    glActiveTexture(GL_TEXTURE0);
    
    //Fix me Bad ACCESS
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _videoTextureCache,
                                                       pixelBuffer,
                                                       NULL,
                                                       GL_TEXTURE_2D,
                                                       GL_RED_EXT,
                                                       frameWidth,
                                                       frameHeight,
                                                       GL_RED_EXT,
                                                       GL_UNSIGNED_BYTE,
                                                       0,
                                                       &_lumaTexture);
    if (err) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    
    glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    if(planeCount == 2) {
        // UV-plane.
        glActiveTexture(GL_TEXTURE1);
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           _videoTextureCache,
                                                           pixelBuffer,
                                                           NULL,
                                                           GL_TEXTURE_2D,
                                                           GL_RG_EXT,
                                                           frameWidth / 2,
                                                           frameHeight / 2,
                                                           GL_RG_EXT,
                                                           GL_UNSIGNED_BYTE,
                                                           1,
                                                           &_chromaTexture);
        if (err) {
            NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    
    
        
    glBindFramebuffer(GL_FRAMEBUFFER, _frameBufferHandle);
    
    
    //setup rotation matrix
    //_attitudeMatrix = GLKMatrix4Multiply([self getDeviceOrientationMatrix], _offsetMatrix);
    
    int dual;
    int renderTimes=(_displayMode<=PANORAMIC_DISPLAY_SINGLE)?1:2;
    //NSLog(@"display mode is %d",_displayMode);
    GLKMatrix4 myTransMatrix=GLKMatrix4Identity;
    for(dual=0;dual<renderTimes;dual++) {
        
        // Set the view port to the entire view.
        if(_displayMode!=PANORAMIC_DISPLAY_DOUBLE) {
            glViewport(0, 0, _backingWidth, _backingHeight);
            
            glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT);
            
        } else {//render dual mode
            
            if(dual==0)
                glViewport(0, 0, _backingWidth/2, _backingHeight);
            else
                glViewport(_backingWidth/2, 0, _backingWidth/2, _backingHeight);
            
            
            if(dual==0) {
                glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
                glClear(GL_COLOR_BUFFER_BIT);
            }
        }
        
        // Use shader program.
        glUseProgram(self.program);
        //    glUniform1f(uniforms[UNIFORM_LUMA_THRESHOLD], 1);
        //    glUniform1f(uniforms[UNIFORM_CHROMA_THRESHOLD], 1);
        glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, GL_FALSE, _preferredConversion);
        

        if(_displayMode>=PANORAMIC_DISPLAY_SINGLE) {
            glUniform1f(uniforms[UNIFORM_SCALE], _scale);
            glUniformMatrix4fv(uniforms[UNIFORM_MVP_MATRIX], 1, GL_FALSE, _projectionMatrix.m);
            glUniformMatrix4fv(uniforms[UNIFORM_ORIENTATION_MATRIX], 1, GL_FALSE, [self getDeviceOrientationMatrix].m);
            glUniformMatrix4fv(uniforms[UNIFORM_ROTATIOM_MATRIX], 1, GL_FALSE, _offsetMatrix.m);
        } else {
            glUniform1f(uniforms[UNIFORM_SCALE], -_scale);
            glUniformMatrix4fv(uniforms[UNIFORM_MVP_MATRIX], 1, GL_FALSE, GLKMatrix4Identity.m);
            glUniformMatrix4fv(uniforms[UNIFORM_ORIENTATION_MATRIX], 1, GL_FALSE, GLKMatrix4Identity.m);
            glUniformMatrix4fv(uniforms[UNIFORM_ROTATIOM_MATRIX], 1, GL_FALSE, GLKMatrix4Identity.m);
        }
        
        if (_displayMode == PANORAMIC_DISPLAY_DOUBLE) {
            GLKMatrix4 tmpMat=GLKMatrix4RotateZ(GLKMatrix4Identity, 3.14/2);
            if (dual==0) {
                //_attitudeMatrix = GLKMatrix4Multiply( GLKMatrix4MakeXRotation(-0.08722), _attitudeMatrix);// 3.14/36=0.08722
                myTransMatrix=GLKMatrix4Multiply(GLKMatrix4MakeXRotation(-0.08722/2.0), tmpMat) ;
            } else { //dual ==1
                //_attitudeMatrix = GLKMatrix4Multiply( GLKMatrix4MakeXRotation(0.08722), _attitudeMatrix);
                myTransMatrix=GLKMatrix4Multiply(GLKMatrix4MakeXRotation(0.08722/2.0), tmpMat) ;
            }
            
            glUniformMatrix4fv(uniforms[UNIFORM_TRANSFORM_MATRIX], 1, GL_FALSE, myTransMatrix.m);
        } else {
            GLKMatrix4 tmpMat=GLKMatrix4RotateZ(GLKMatrix4Identity, 3.14/2);
            glUniformMatrix4fv(uniforms[UNIFORM_TRANSFORM_MATRIX], 1, GL_FALSE, tmpMat.m);
        }
        
        // Set up the quad vertices with respect to the orientation and aspect ratio of the video.
        CGRect viewBounds = self.bounds;
        CGRect viewBoundtrans = CGRectMake(viewBounds.origin.y, viewBounds.origin.x, viewBounds.size.height, viewBounds.size.width);
        //CGSize contentSize = CGSizeMake(frameWidth, frameHeight);
        CGSize contentSize = CGSizeMake(frameHeight, frameWidth);
        CGRect vertexSamplingRect = AVMakeRectWithAspectRatioInsideRect(contentSize, viewBoundtrans);
        
        // Compute normalized quad coordinates to draw the frame into.
        CGSize normalizedSamplingSize = CGSizeMake(0.0, 0.0);
        CGSize cropScaleAmount = CGSizeMake(vertexSamplingRect.size.width/viewBoundtrans.size.width,
                                            vertexSamplingRect.size.height/viewBoundtrans.size.height);
        
        // Normalize the quad vertices.
        if (cropScaleAmount.width > cropScaleAmount.height) {
            normalizedSamplingSize.width = 1.0;
            normalizedSamplingSize.height = cropScaleAmount.height/cropScaleAmount.width;
        }
        else {
            normalizedSamplingSize.width = cropScaleAmount.width/cropScaleAmount.height;
            normalizedSamplingSize.height = 1.0;;
        }
        
        
        // The quad vertex data defines the region of 2D plane onto which we draw our pixel buffers.
        // Vertex data formed using (-1,-1) and (1,1) as the bottom left and top right coordinates respectively, covers the entire screen.
        
        GLfloat quadVertexData [] = {
            -1 * normalizedSamplingSize.width, normalizedSamplingSize.height,
            -1 * normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
            normalizedSamplingSize.width, normalizedSamplingSize.height,
            normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
        };
        
        
        // The texture vertices are set up such that we flip the texture vertically. This is so that our top left origin buffers match OpenGL's bottom left texture coordinate system.
        CGRect textureSamplingRect = CGRectMake(0, 0, 1, 1);
        GLfloat quadTextureData[] =  {
            CGRectGetMinX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
            CGRectGetMaxX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
            CGRectGetMinX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
            CGRectGetMaxX(textureSamplingRect), CGRectGetMinY(textureSamplingRect)
        };
        
        GLfloat *vertexArray=(_displayMode>=PANORAMIC_DISPLAY_SINGLE)?[sphere getVertexData]:quadVertexData;
        GLfloat *textureArray=(_displayMode>=PANORAMIC_DISPLAY_SINGLE)?[sphere getTextureData]:quadTextureData;
        // Update attribute values.
        glVertexAttribPointer(ATTRIB_VERTEX, (_displayMode>=PANORAMIC_DISPLAY_SINGLE)?3:2, GL_FLOAT, 1, 0, vertexArray);
        glEnableVertexAttribArray(ATTRIB_VERTEX);
        glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, 1, 0, textureArray);
        glEnableVertexAttribArray(ATTRIB_TEXCOORD);
        
        glDrawArrays(GL_TRIANGLE_STRIP, 0, (_displayMode>=PANORAMIC_DISPLAY_SINGLE)?[sphere getArrayCount]:4);
        
    }//end of dual

    
    glBindRenderbuffer(GL_RENDERBUFFER, _colorBufferHandle);
        
    [_context presentRenderbuffer:GL_RENDERBUFFER];


    
    [self cleanUpTextures];
    // Periodic texture cache flush every frame
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
    
    if(_videoTextureCache) {
        CFRelease(_videoTextureCache);
    }
}

# pragma mark - OpenGL setup
-(void)initOpenGL{
    //setup view, and context
    [self setOpaque:NO];
    _scale=-1;
    _aspectRatio = self.frame.size.width/self.frame.size.height;
    _fieldOfView = 45 + 45 * atanf(_aspectRatio); // hell ya
    [self rebuildProjectionMatrix];
    _attitudeMatrix = GLKMatrix4Identity;
    _offsetMatrix = GLKMatrix4Identity;
    
    if (!_context || ![EAGLContext setCurrentContext:_context]) {
        return;
    }
    
    
    
    //setup shader code
    [self setupBuffers];
    [self loadShaders];
    
    glUseProgram(self.program);
    
    // 0 and 1 are the texture IDs of _lumaTexture and _chromaTexture respectively.
    glUniform1i(uniforms[UNIFORM_Y], 0);
    glUniform1i(uniforms[UNIFORM_UV], 1);
    glUniform1f(uniforms[UNIFORM_SCALE], _scale);
    glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, GL_FALSE, _preferredConversion);
    glUniformMatrix4fv(uniforms[UNIFORM_MVP_MATRIX], 1, GL_FALSE, _projectionMatrix.m);
    glUniformMatrix4fv(uniforms[UNIFORM_ORIENTATION_MATRIX], 1, GL_FALSE, GLKMatrix4Identity.m);
    glUniformMatrix4fv(uniforms[UNIFORM_ROTATIOM_MATRIX], 1, GL_FALSE, GLKMatrix4Identity.m);
    glUniformMatrix4fv(uniforms[UNIFORM_TRANSFORM_MATRIX], 1, GL_FALSE, GLKMatrix4Identity.m);

}

-(void)rebuildProjectionMatrix{
    GLfloat frustum = Z_NEAR * tanf(_fieldOfView*0.00872664625997);  // pi/180/2
    _projectionMatrix = GLKMatrix4MakeFrustum(-frustum, frustum, -frustum/_aspectRatio, frustum/_aspectRatio, Z_NEAR, Z_FAR);
}

#pragma mark - Utilities

- (void)setupBuffers
{
    glDisable(GL_DEPTH_TEST);
    
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), 0);
    
    glEnableVertexAttribArray(ATTRIB_TEXCOORD);
    glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), 0);
    
    [self createBuffers];
}

- (void) createBuffers
{
    glGenFramebuffers(1, &_frameBufferHandle);
    glBindFramebuffer(GL_FRAMEBUFFER, _frameBufferHandle);
    
    glGenRenderbuffers(1, &_colorBufferHandle);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorBufferHandle);
    
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:self];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
    
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorBufferHandle);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"Failed to make complete framebuffer object %x", glCheckFramebufferStatus(GL_FRAMEBUFFER));
    }
}

- (void) releaseBuffers
{
    if(_frameBufferHandle) {
        glDeleteFramebuffers(1, &_frameBufferHandle);
        _frameBufferHandle = 0;
    }
    
    if(_colorBufferHandle) {
        glDeleteRenderbuffers(1, &_colorBufferHandle);
        _colorBufferHandle = 0;
    }
}

- (void) resetRenderBuffer
{
    if (!_context || ![EAGLContext setCurrentContext:_context]) {
        return;
    }
    
    [self releaseBuffers];
    [self createBuffers];
}

- (void) cleanUpTextures
{
    if (_lumaTexture) {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;
    }
    
    if (_chromaTexture) {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
}

#pragma mark -  OpenGL ES 2 shader compilation

const GLchar *shader_fsh = (const GLchar*)"varying highp vec2 texCoordVarying;"
"precision mediump float;"
"uniform sampler2D SamplerY;"
"uniform sampler2D SamplerUV;"
"uniform mat3 colorConversionMatrix;"
"void main()"
"{"
"    mediump vec3 yuv;"
"    lowp vec3 rgb;"
//   Subtract constants to map the video range start at 0
"    yuv.x = (texture2D(SamplerY, texCoordVarying).r - (16.0/255.0));"
"    yuv.yz = (texture2D(SamplerUV, texCoordVarying).rg - vec2(0.5, 0.5));"
"    rgb = colorConversionMatrix * yuv;"
"    gl_FragColor = vec4(rgb, 1);"
"}";

const GLchar *shader_vsh = (const GLchar*)"attribute vec4 position;"
"attribute vec2 texCoord;"
"uniform float scale;"
"uniform mat4 mdvMatrix;"
"uniform mat4 orientationMatrix;"
"uniform mat4 rotationMatrix;"
"uniform mat4 transformMatrix;"
"varying vec2 texCoordVarying;"
"void main()"
"{"
"    vec4 Vertex = position;"
"    Vertex.y = Vertex.y*scale;"
"    gl_Position = mdvMatrix * transformMatrix * orientationMatrix * rotationMatrix * Vertex;"
"    texCoordVarying = texCoord;"
"}";


- (BOOL)loadShaders
{
    GLuint vertShader = 0, fragShader = 0;
    
    // Create the shader program.
    self.program = glCreateProgram();
    
    if(![self compileShaderString:&vertShader type:GL_VERTEX_SHADER shaderString:shader_vsh]) {
        NSLog(@"Failed to compile vertex shader");
        return NO;
    }
    
    if(![self compileShaderString:&fragShader type:GL_FRAGMENT_SHADER shaderString:shader_fsh]) {
        NSLog(@"Failed to compile fragment shader");
        return NO;
    }
    
    // Attach vertex shader to program.
    glAttachShader(self.program, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(self.program, fragShader);
    
    // Bind attribute locations. This needs to be done prior to linking.
    glBindAttribLocation(self.program, ATTRIB_VERTEX, "position");
    glBindAttribLocation(self.program, ATTRIB_TEXCOORD, "texCoord");
    
    // Link the program.
    if (![self linkProgram:self.program]) {
        NSLog(@"Failed to link program: %d", self.program);
        
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (self.program) {
            glDeleteProgram(self.program);
            self.program = 0;
        }
        
        return NO;
    }
    
    // Get uniform locations.
    uniforms[UNIFORM_Y] = glGetUniformLocation(self.program, "SamplerY");
    uniforms[UNIFORM_UV] = glGetUniformLocation(self.program, "SamplerUV");
    //    uniforms[UNIFORM_LUMA_THRESHOLD] = glGetUniformLocation(self.program, "lumaThreshold");
    //    uniforms[UNIFORM_CHROMA_THRESHOLD] = glGetUniformLocation(self.program, "chromaThreshold");
    uniforms[UNIFORM_SCALE] = glGetUniformLocation(self.program, "scale");
    uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = glGetUniformLocation(self.program, "colorConversionMatrix");
    uniforms[UNIFORM_MVP_MATRIX] = glGetUniformLocation(self.program, "mdvMatrix");
    uniforms[UNIFORM_ORIENTATION_MATRIX] = glGetUniformLocation(self.program, "orientationMatrix");
    uniforms[UNIFORM_ROTATIOM_MATRIX] = glGetUniformLocation(self.program, "rotationMatrix");
    uniforms[UNIFORM_TRANSFORM_MATRIX] = glGetUniformLocation(self.program, "transformMatrix");
    
    // Release vertex and fragment shaders.
    if (vertShader) {
        glDetachShader(self.program, vertShader);
        glDeleteShader(vertShader);
    }
    if (fragShader) {
        glDetachShader(self.program, fragShader);
        glDeleteShader(fragShader);
    }
    
    return YES;
}

- (BOOL)compileShaderString:(GLuint *)shader type:(GLenum)type shaderString:(const GLchar*)shaderString
{
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &shaderString, NULL);
    glCompileShader(*shader);
    
#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    GLint status = 0;
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(*shader);
        return NO;
    }
    
    return YES;
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type URL:(NSURL *)URL
{
    NSError *error;
    NSString *sourceString = [[NSString alloc] initWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:&error];
    if (sourceString == nil) {
        NSLog(@"Failed to load vertex shader: %@", [error localizedDescription]);
        return NO;
    }
    
    const GLchar *source = (GLchar *)[sourceString UTF8String];
    
    return [self compileShaderString:shader type:type shaderString:source];
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
    GLint logLength, status;
    
    glValidateProgram(prog);
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (void)dealloc
{
    if (!_context || ![EAGLContext setCurrentContext:_context]) {
        return;
    }
    
    [self cleanUpTextures];
    
    if(_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
    }
    
    if (self.program) {
        glDeleteProgram(self.program);
        self.program = 0;
    }
    if(_context) {
        [_context release];
        _context = nil;
    }
    [super dealloc];
}

@end

@interface Sphere (){
    //  from Touch Fighter by Apple
    //  in Pro OpenGL ES for iOS
    //  by Mike Smithwick Jan 2011 pg. 78
    GLKTextureInfo *m_TextureInfo;
    GLfloat *m_TexCoordsData;
    GLfloat *m_VertexData;
    GLfloat *m_NormalData;
    GLint m_Stacks, m_Slices;
    GLfloat m_Scale;
}
@end

//sphere def
@implementation Sphere
-(id) init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile{
    // modifications:
    //   flipped(inverted) texture coords across the Z
    //   vertices rotated 90deg
    m_Scale = radius;
    if((self = [super init])){
        m_Stacks = stacks;
        m_Slices = slices;
        m_VertexData = nil;
        m_TexCoordsData = nil;
        // Vertices
        NSLog(@"assign vertex data stacks %d, slices %d", stacks, slices);
        GLfloat *vPtr  = m_VertexData = (GLfloat*)malloc(sizeof(GLfloat) * 3 * ((m_Slices*2+2) * (m_Stacks)));
        // Normals
        GLfloat *nPtr = m_NormalData = (GLfloat*)malloc(sizeof(GLfloat) * 3 * ((m_Slices*2+2) * (m_Stacks)));
        GLfloat *tPtr = nil;
        tPtr = m_TexCoordsData = (GLfloat*)malloc(sizeof(GLfloat) * 2 * ((m_Slices*2+2) * (m_Stacks)));
        unsigned int phiIdx, thetaIdx;
        // Latitude
        for(phiIdx = 0; phiIdx < m_Stacks; phiIdx++){
            //starts at -pi/2 goes to pi/2
            //the first circle
            float phi0 = M_PI * ((float)(phiIdx+0) * (1.0/(float)(m_Stacks)) - 0.5);
            //second one
            float phi1 = M_PI * ((float)(phiIdx+1) * (1.0/(float)(m_Stacks)) - 0.5);
            float cosPhi0 = cos(phi0);
            float sinPhi0 = sin(phi0);
            float cosPhi1 = cos(phi1);
            float sinPhi1 = sin(phi1);
            float cosTheta, sinTheta;
            //longitude
            for(thetaIdx = 0; thetaIdx < m_Slices; thetaIdx++){
                float theta = -2.0*M_PI * ((float)thetaIdx) * (1.0/(float)(m_Slices - 1));
                cosTheta = cos(theta+M_PI*.5);
                sinTheta = sin(theta+M_PI*.5);
                //get x-y-x of the first vertex of stack
                vPtr[0] = m_Scale*cosPhi0 * cosTheta;
                vPtr[1] = m_Scale*sinPhi0;
                vPtr[2] = m_Scale*(cosPhi0 * sinTheta);
                //the same but for the vertex immediately above the previous one.
                vPtr[3] = m_Scale*cosPhi1 * cosTheta;
                vPtr[4] = m_Scale*sinPhi1;
                vPtr[5] = m_Scale*(cosPhi1 * sinTheta);
                nPtr[0] = cosPhi0 * cosTheta;
                nPtr[1] = sinPhi0;
                nPtr[2] = cosPhi0 * sinTheta;
                nPtr[3] = cosPhi1 * cosTheta;
                nPtr[4] = sinPhi1;
                nPtr[5] = cosPhi1 * sinTheta;
                if(tPtr!=nil){
                    GLfloat texX = (float)thetaIdx * (1.0f/(float)(m_Slices-1));
                    tPtr[0] = 1.0-texX;
                    tPtr[1] = (float)(phiIdx + 0) * (1.0f/(float)(m_Stacks));
                    tPtr[2] = 1.0-texX;
                    tPtr[3] = (float)(phiIdx + 1) * (1.0f/(float)(m_Stacks));
                }
                vPtr += 2*3;
                nPtr += 2*3;
                if(tPtr != nil) tPtr += 2*2;
            }
            //Degenerate triangle to connect stacks and maintain winding order
            vPtr[0] = vPtr[3] = vPtr[-3];
            vPtr[1] = vPtr[4] = vPtr[-2];
            vPtr[2] = vPtr[5] = vPtr[-1];
            nPtr[0] = nPtr[3] = nPtr[-3];
            nPtr[1] = nPtr[4] = nPtr[-2];
            nPtr[2] = nPtr[5] = nPtr[-1];
            if(tPtr != nil){
                tPtr[0] = tPtr[2] = tPtr[-2];
                tPtr[1] = tPtr[3] = tPtr[-1];
            }
        }
    }
    return self;
}
-(void) dealloc{
    GLuint name = m_TextureInfo.name;
    glDeleteTextures(1, &name);
    
    if(m_TexCoordsData != nil){
        free(m_TexCoordsData);
    }
    if(m_NormalData != nil){
        free(m_NormalData);
    }
    if(m_VertexData != nil){
        free(m_VertexData);
    }
    [super dealloc];
}

-(GLfloat*) getVertexData{
    return m_VertexData;
}

-(GLfloat*) getTextureData{
    return m_TexCoordsData;
}

-(GLfloat*) getNormalData{
    return m_NormalData;
}

-(GLint) getArrayCount{
    return ((m_Slices +1) * 2 * (m_Stacks-1)+2);
}

@end
