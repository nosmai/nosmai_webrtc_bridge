#import "NosmaiWebRtcBridgePlugin.h"
#import "NosmaiFramePump.h"

/// Nosmai <-> flutter_webrtc bridge, iOS. Same method channel and semantics as Android.
@implementation NosmaiWebRtcBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"nosmai_webrtc_bridge"
                                  binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:[[NosmaiWebRtcBridgePlugin alloc] init] channel:channel];
}

static NSInteger IntArg(FlutterMethodCall *call, NSString *key) {
  id v = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments[key] : nil;
  return [v isKindOfClass:NSNumber.class] ? [v integerValue] : 0;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NosmaiFramePump *pump = NosmaiFramePump.shared;
  NSString *m = call.method;

  if ([m isEqualToString:@"registerShareContext"]) {
    // Android joins flutter_webrtc's EGL share group. iOS hands over IOSurface-backed
    // CVPixelBuffers that need no shared GL context, so this is a deliberate no-op that lets app
    // code call it unconditionally (it still must precede Nosmai init on Android).
    result(@(0));
  } else if ([m isEqualToString:@"startStreaming"]) {
    NSError *error = nil;
    NSString *trackId = [pump startStreamingWithWidth:IntArg(call, @"width")
                                               height:IntArg(call, @"height")
                                                  fps:IntArg(call, @"fps")
                                                error:&error];
    if (!trackId) {
      result([FlutterError errorWithCode:@"START_FAILED"
                                 message:error.localizedDescription ?: @"unknown"
                                 details:nil]);
    } else {
      result(@{@"trackId" : trackId, @"label" : @"nosmai"});
    }
  } else if ([m isEqualToString:@"stopStreaming"]) {
    [pump stopStreaming];
    result(nil);
  } else if ([m isEqualToString:@"isStreaming"]) {
    result(@(pump.streaming));
  } else if ([m isEqualToString:@"setRotation"]) {
    pump.rotationDegrees = IntArg(call, @"degrees");
    result(nil);
  } else if ([m isEqualToString:@"setMirror"]) {
    id v = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments[@"mirror"] : nil;
    pump.mirrorX = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
    result(nil);
  } else if ([m isEqualToString:@"getCounters"]) {
    result([pump counters]);
  } else if ([m isEqualToString:@"getPlatformVersion"]) {
    result([@"iOS " stringByAppendingString:UIDevice.currentDevice.systemVersion]);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [NosmaiFramePump.shared stopStreaming];
}

@end
