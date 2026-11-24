#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Publishes Nosmai's processed output as a flutter_webrtc local video track.
 *
 * Model: Nosmai owns the camera AND the on-screen preview (nosmai_camera_sdk); WebRTC only encodes
 * and transports. WebRTC must never open a camera.
 */
@interface NosmaiFramePump : NSObject

+ (instancetype)shared;

@property(atomic, readonly) BOOL streaming;
/// Horizontal flip of the STREAM (not the preview). Latched across streams.
@property(atomic, assign) BOOL mirrorX;
/// Rotation metadata (0/90/180/270). 0 is correct: Nosmai delivers upright portrait frames.
@property(atomic, assign) NSInteger rotationDegrees;

/// @return the native track id, or nil with [error] set.
- (nullable NSString *)startStreamingWithWidth:(NSInteger)width
                                        height:(NSInteger)height
                                           fps:(NSInteger)fps
                                         error:(NSError *_Nullable *_Nullable)error;
- (void)stopStreaming;

/// Monotonic counters (same keys as Android). Empty when not streaming.
- (NSDictionary<NSString *, NSNumber *> *)counters;

@end

NS_ASSUME_NONNULL_END
