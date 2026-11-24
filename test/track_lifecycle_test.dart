import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_webrtc_bridge/nosmai_webrtc_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const rtc = MethodChannel('FlutterWebRTC.Method');
  const bridge = MethodChannel('nosmai_webrtc_bridge');
  final calls = <String>[];
  late Completer<void> starting;
  late Completer<void> allowStart;
  bool failAttach = false;

  setUp(() {
    calls.clear();
    failAttach = false;
    starting = Completer<void>();
    allowStart = Completer<void>();
    messenger.setMockMethodCallHandler(rtc, (call) async {
      calls.add(call.method);
      if (call.method == 'createLocalMediaStream') return {'streamId': 'local'};
      if (call.method == 'mediaStreamAddTrack' && failAttach) {
        throw PlatformException(code: 'attach_failed');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(bridge, (call) async {
      calls.add(call.method);
      if (call.method == 'startStreaming') {
        if (!starting.isCompleted) starting.complete();
        await allowStart.future;
        return {'trackId': 'video-test', 'label': 'nosmai'};
      }
      return null;
    });
  });

  tearDown(() async {
    if (!allowStart.isCompleted) allowStart.complete();
    await NosmaiWebRtcBridge.stopStreaming();
    messenger.setMockMethodCallHandler(bridge, null);
    messenger.setMockMethodCallHandler(rtc, null);
  });

  test(
    'leave during start releases the registered stream and producer once',
    () async {
      final create = NosmaiWebRtcBridge.createVideoTrack();
      await starting.future;
      final stop = NosmaiWebRtcBridge.stopStreaming();
      final stopAgain = NosmaiWebRtcBridge.stopStreaming();
      allowStart.complete();
      expect((await create).track.id, 'video-test');
      await Future.wait([stop, stopAgain]);
      expect(calls.where((call) => call == 'stopStreaming'), hasLength(1));
      expect(
        calls,
        containsAllInOrder([
          'mediaStreamAddTrack',
          'streamDispose',
          'stopStreaming',
        ]),
      );
    },
  );

  test(
    'failed track attachment releases native capture and permits another call',
    () async {
      failAttach = true;
      allowStart.complete();
      await expectLater(
        NosmaiWebRtcBridge.createVideoTrack(),
        throwsA(isA<PlatformException>()),
      );
      expect(
        calls,
        containsAllInOrder([
          'mediaStreamAddTrack',
          'streamDispose',
          'stopStreaming',
        ]),
      );
      failAttach = false;
      expect(
        (await NosmaiWebRtcBridge.createVideoTrack()).track.id,
        'video-test',
      );
      await expectLater(
        NosmaiWebRtcBridge.createVideoTrack(),
        throwsStateError,
      );
      expect(calls.where((call) => call == 'startStreaming'), hasLength(2));
    },
  );
}
