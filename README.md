# Nosmai WebRTC Bridge for Flutter

Publish a Nosmai camera with beauty effects and filters through your app’s existing `flutter_webrtc` peer connection on Android and iOS. The bridge supplies the outgoing video track. Your app continues to handle the microphone, signalling, ICE servers and remote video tiles.

## Install

Add the bridge and its dependencies to your Flutter app’s `pubspec.yaml`.

```yaml
dependencies:
  flutter_webrtc: 1.6.0
  nosmai_effects_sdk: 2.0.2
  nosmai_webrtc_bridge:
    git: https://github.com/nosmai/nosmai_webrtc_bridge.git
```

Run `flutter pub get` and rebuild the app. Pin `flutter_webrtc` to 1.6.0 because the bridge registers its native video track with this version of the plugin.

- **Android** requires API 24 or later. Declare internet and camera permissions, and microphone permission for audio calls. The Effects package supplies the native Nosmai SDK.
- **iOS** requires iOS 15 or later and CocoaPods. Add `NSCameraUsageDescription` and, for audio calls, `NSMicrophoneUsageDescription` to `Info.plist`. The LAN example also uses `NSLocalNetworkUsageDescription`. Apps using `permission_handler` with CocoaPods can copy the camera and microphone permission flags from the [example Podfile](example/ios/Podfile).
- Use a Nosmai license issued for the sender’s Android application ID or iOS bundle ID. A receiver can use a standard WebRTC client.

## Initialize and preview

Import the following packages on the sender screen.

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
import 'package:nosmai_webrtc_bridge/nosmai_webrtc_bridge.dart';
```

Request camera access through your app’s usual permission flow. Before the first Nosmai initialization, register WebRTC’s graphics context. Both platforms use this sequence.

```dart
Future<void> initializeCamera(String licenseKey) async {
  if (await NosmaiWebRtcBridge.registerShareContext() == null) {
    throw StateError('Could not prepare the WebRTC camera.');
  }
  if (!await NosmaiFlutter.initialize(licenseKey)) {
    throw StateError('Check the Nosmai license for this app.');
  }
}
```

If your app already captures camera video using `getUserMedia`, stop the old camera track before mounting `NosmaiCameraPreview`. Keep the existing microphone track. Declare `bool cameraReady = false` and `String? cameraError` in your screen’s `State`. Enable publishing when the local preview is ready and keep the preview mounted throughout the call.

```dart
NosmaiCameraPreview(
  onInitialized: () => setState(() => cameraReady = true),
  onError: (message) => setState(() {
    cameraReady = false;
    cameraError = message;
  }),
)
```

## Publish to your existing peer connection

**If the call already has a camera sender**, use the `RTCRtpSender` your app retained when it added its original camera. Only its video source changes.

```dart
final video = await NosmaiWebRtcBridge.createVideoTrack();
try {
  await videoSender.replaceTrack(video.track);
} catch (_) {
  await NosmaiWebRtcBridge.stopStreaming();
  rethrow;
}
```

**If the connection has no video sender yet**, use `await pc.addTrack(video.track, video.stream)` in place of `replaceTrack` above. Save the sender returned by `addTrack` and continue your normal offer/answer and ICE exchange. Allow one active bridge track at a time. Route subsequent effect changes through Nosmai, for example `await NosmaiFlutter.instance.applySkinSmoothing(0.6)`.

## Stop publishing

To stop just the camera during a call, detach its track and stop the bridge. The microphone and peer connection can continue.

```dart
try {
  await videoSender.replaceTrack(null);
} finally {
  await NosmaiWebRtcBridge.stopStreaming();
}
```

When ending the whole call, stop the bridge before closing the peer connection, then release the microphone through its existing owner. When leaving the camera screen, end the Nosmai camera session and remove the preview. To publish again, create a fresh bridge track.

## Example

The example includes a Flutter sender and viewer, plus a local signalling server with a browser viewer. It uses `com.nosmai.webrtcbridge.example` on Android and iOS. [Run the example](example/README.md)
