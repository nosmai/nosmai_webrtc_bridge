#import "NosmaiFramePump.h"

#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <WebRTC/WebRTC.h>
#import <nosmai/Nosmai.h>
#import <mach/mach_time.h>
#import <stdatomic.h>

#import "FlutterWebRTCPlugin.h"
#import "LocalVideoTrack.h"

static NSString *const kErrDomain = @"NosmaiFramePump";
static NSError *PumpError(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:kErrDomain code:code userInfo:@{NSLocalizedDescriptionKey : msg}];
}

@interface NosmaiFramePump () {
  // Written from the Nosmai worker thread, read from the platform thread.
  _Atomic uint64_t _nosmaiFrames;
  _Atomic uint64_t _pushedFrames;
  _Atomic uint64_t _droppedFrames;
  _Atomic uint64_t _blitNanos;
  _Atomic int _lastWidth;
  _Atomic int _lastHeight;
}
@property(atomic, readwrite) BOOL streaming;
@property(atomic, strong, nullable) RTCVideoSource *videoSource;
@property(nonatomic, strong, nullable) RTCVideoTrack *videoTrack;
@property(nonatomic, copy, nullable) NSString *trackId;

// Mirror path: GPU flip into a pooled IOSurface-backed buffer. Only touched on the Nosmai worker.
@property(nonatomic, strong, nullable) CIContext *ciContext;
@property(nonatomic, assign) CVPixelBufferPoolRef mirrorPool;
@property(nonatomic, assign) size_t poolW;
@property(nonatomic, assign) size_t poolH;
@property(nonatomic, assign) OSType poolFormat;
@end

@implementation NosmaiFramePump

+ (instancetype)shared {
  static NosmaiFramePump *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[NosmaiFramePump alloc] init]; });
  return instance;
}

#pragma mark - Start / stop

- (nullable NSString *)startStreamingWithWidth:(NSInteger)width
                                        height:(NSInteger)height
                                           fps:(NSInteger)fps
                                         error:(NSError **)outError {
  if (self.streaming) [self stopStreaming];

  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (!plugin) {
    if (outError) *outError = PumpError(1, @"FlutterWebRTCPlugin.sharedSingleton is nil");
    return nil;
  }
  // Dart initializes the WebRTC factory before requesting a track.
  RTCPeerConnectionFactory *factory = plugin.peerConnectionFactory;
  if (!factory) {
    if (outError) *outError = PumpError(2, @"peerConnectionFactory is nil (WebRTC not initialized)");
    return nil;
  }
  NosmaiCore *core = [NosmaiCore shared];
  if (!core) {
    if (outError) *outError = PumpError(3, @"NosmaiCore unavailable. Is NosmaiFlutter.initialize() done?");
    return nil;
  }

  RTCVideoSource *source = [factory videoSource];
  if (width > 0 && height > 0 && fps > 0) {
    [source adaptOutputFormatToWidth:(int)width height:(int)height fps:(int)fps];
  }
  NSString *trackId = [NSString stringWithFormat:@"nosmai-%@", [[NSUUID UUID] UUIDString]];
  RTCVideoTrack *track = [factory videoTrackWithSource:source trackId:trackId];

  // localTracks is a public readwrite property on iOS, so registration is a plain dictionary write.
  if (!plugin.localTracks) plugin.localTracks = [NSMutableDictionary dictionary];
  plugin.localTracks[trackId] = [[LocalVideoTrack alloc] initWithTrack:track];

  self.videoSource = source;
  self.videoTrack = track;
  self.trackId = trackId;
  RTCVideoCapturer *capturer = [[RTCVideoCapturer alloc] initWithDelegate:nil];
  atomic_store(&_nosmaiFrames, 0);
  atomic_store(&_pushedFrames, 0);
  atomic_store(&_droppedFrames, 0);
  atomic_store(&_blitNanos, 0);
  atomic_store(&_lastWidth, 0);
  atomic_store(&_lastHeight, 0);
  self.streaming = YES;

  // Official live-stream hook: fans out alongside Nosmai recording, so it never detaches it
  // (the lower-level NosmaiSDK setCVPixelBufferCallback: would). Setting it arms the output.
  __weak typeof(self) weakSelf = self;
  core.liveFrameStreamCallback = ^(CVPixelBufferRef pixelBuffer, double timestamp) {
    [weakSelf onNosmaiFrame:pixelBuffer timestamp:timestamp source:source capturer:capturer];
  };

  NSLog(@"[NosmaiFramePump] streaming: track %@ armed", trackId);
  return trackId;
}

- (void)stopStreaming {
  if (!self.streaming) return;
  // Disarm the PRODUCER first so no frame races the source being torn down.
  self.streaming = NO;
  [NosmaiCore shared].liveFrameStreamCallback = nil;

  if (self.trackId) {
    FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
    [plugin.localTracks removeObjectForKey:self.trackId];
  }
  NSLog(@"[NosmaiFramePump] stopped (nosmai=%llu pushed=%llu dropped=%llu)",
        atomic_load(&_nosmaiFrames), atomic_load(&_pushedFrames), atomic_load(&_droppedFrames));
  self.videoTrack = nil;
  self.videoSource = nil;
  self.trackId = nil;
  @synchronized(self) {
    if (_mirrorPool) {
      CVPixelBufferPoolRelease(_mirrorPool);
      _mirrorPool = NULL;
    }
    _poolW = _poolH = 0;
  }
}

- (NSDictionary<NSString *, NSNumber *> *)counters {
  if (!self.streaming) return @{};
  return @{
    @"nosmaiFrames" : @(atomic_load(&_nosmaiFrames)),
    @"pushedFrames" : @(atomic_load(&_pushedFrames)),
    @"droppedFrames" : @(atomic_load(&_droppedFrames)),
    @"blitNanos" : @(atomic_load(&_blitNanos)),
    @"width" : @(atomic_load(&_lastWidth)),
    @"height" : @(atomic_load(&_lastHeight)),
  };
}

#pragma mark - Frame path

/**
 * Called on Nosmai's worker thread. Do the minimum: (optionally flip,) wrap, hand off.
 * RTCCVPixelBuffer retains the buffer and the source/encoder retain the frame as long as they need
 * it, so a synchronous push is safe. Nosmai's producer pool is small and drops silently when
 * full, so never hold a buffer beyond this call.
 */
- (void)onNosmaiFrame:(CVPixelBufferRef)pixelBuffer timestamp:(double)timestamp
               source:(RTCVideoSource *)source capturer:(RTCVideoCapturer *)capturer {
  atomic_fetch_add(&_nosmaiFrames, 1);
  if (!self.streaming || pixelBuffer == NULL || source != self.videoSource) {
    atomic_fetch_add(&_droppedFrames, 1);
    return;
  }

  uint64_t t0 = mach_absolute_time();
  CVPixelBufferRef out = pixelBuffer;
  CVPixelBufferRef flipped = NULL;
  if (self.mirrorX) {
    flipped = [self newMirroredCopyOf:pixelBuffer];
    if (flipped) out = flipped;  // on failure fall back to the unflipped frame rather than drop
  }

  RTCCVPixelBuffer *buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:out];
  RTCVideoRotation rotation = RTCVideoRotation_0;
  switch (self.rotationDegrees) {
    case 90: rotation = RTCVideoRotation_90; break;
    case 180: rotation = RTCVideoRotation_180; break;
    case 270: rotation = RTCVideoRotation_270; break;
    default: break;
  }
  // Nosmai timestamps are seconds; fall back to the media clock if one is ever missing.
  double ts = timestamp > 0 ? timestamp : CACurrentMediaTime();
  RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:buffer
                                                      rotation:rotation
                                                   timeStampNs:(int64_t)(ts * NSEC_PER_SEC)];
  [source capturer:capturer didCaptureVideoFrame:frame];
  if (flipped) CVPixelBufferRelease(flipped);

  atomic_fetch_add(&_pushedFrames, 1);
  atomic_store(&_lastWidth, (int)CVPixelBufferGetWidth(pixelBuffer));
  atomic_store(&_lastHeight, (int)CVPixelBufferGetHeight(pixelBuffer));
  static mach_timebase_info_data_t tb;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ mach_timebase_info(&tb); });
  atomic_fetch_add(&_blitNanos, (mach_absolute_time() - t0) * tb.numer / tb.denom);
}

/// Returns a +1 retained horizontally flipped copy, or NULL on failure.
- (CVPixelBufferRef)newMirroredCopyOf:(CVPixelBufferRef)src {
  @synchronized(self) {  // pool is released in -stopStreaming on another thread
  size_t w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
  OSType fmt = CVPixelBufferGetPixelFormatType(src);
  if (!self.ciContext) self.ciContext = [CIContext contextWithOptions:nil];
  if (!_mirrorPool || _poolW != w || _poolH != h || _poolFormat != fmt) {
    if (_mirrorPool) CVPixelBufferPoolRelease(_mirrorPool);
    _mirrorPool = NULL;
    NSDictionary *attrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(fmt),
      (id)kCVPixelBufferWidthKey : @(w),
      (id)kCVPixelBufferHeightKey : @(h),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs,
                                &_mirrorPool) != kCVReturnSuccess) {
      _mirrorPool = NULL;
      return NULL;
    }
    _poolW = w; _poolH = h; _poolFormat = fmt;
  }
  CVPixelBufferRef dst = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _mirrorPool, &dst) != kCVReturnSuccess) {
    return NULL;
  }
  CIImage *img = [CIImage imageWithCVPixelBuffer:src];
  CIImage *flip = [img imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, 1, (CGFloat)w, 0)];
  [self.ciContext render:flip toCVPixelBuffer:dst];
  return dst;
  }
}

- (void)dealloc {
  if (_mirrorPool) CVPixelBufferPoolRelease(_mirrorPool);
}

@end
