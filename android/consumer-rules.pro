# flutter_webrtc 1.6.0 does not expose its track registrar.
-keepclassmembers class com.cloudwebrtc.webrtc.FlutterWebRTCPlugin {
    *** methodCallHandler;
}
