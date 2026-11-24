import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
import 'package:nosmai_webrtc_bridge/nosmai_webrtc_bridge.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'effects_sheet.dart';
import 'viewer_page.dart';

void main() => runApp(const ExampleApp());

/// Connects the signalling WebSocket, retrying for ~30 s. On iOS the first LAN connection fails
/// with "No route to host" while the Local Network permission prompt is pending, or if it was denied.
Future<WebSocket> connectSignalling(String url, {void Function(int attempt, Object error)? onRetry}) async {
  for (var attempt = 1;; attempt++) {
    try {
      return await WebSocket.connect(url).timeout(const Duration(seconds: 5));
    } catch (e) {
      if (attempt >= 15) rethrow;
      debugPrint('[example] signalling attempt $attempt failed: $e');
      onRetry?.call(attempt, e);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Nosmai WebRTC Bridge',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
        home: const SetupPage(),
      );
}

/// Collects the signalling URL and licence key, then opens the sender screen.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _server = TextEditingController(text: const String.fromEnvironment('SIGNAL_URL', defaultValue: 'ws://192.168.1.2:8080'));
  final _room = TextEditingController(text: const String.fromEnvironment('ROOM', defaultValue: 'qa'));
  final _license = TextEditingController(text: const String.fromEnvironment('NOSMAI_LICENSE'));

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _server.text = const bool.hasEnvironment('SIGNAL_URL') ? _server.text : (p.getString('server') ?? _server.text);
        _room.text = const bool.hasEnvironment('ROOM') ? _room.text : (p.getString('room') ?? _room.text);
        _license.text = _license.text.isNotEmpty ? _license.text : (p.getString('license') ?? '');
      });
    });
  }

  Future<void> _openViewer() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('server', _server.text.trim());
    await p.setString('room', _room.text.trim());
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerPage(
        serverUrl: _server.text.trim(),
        room: _room.text.trim().isEmpty ? 'qa' : _room.text.trim(),
      ),
    ));
  }

  Future<void> _open() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('server', _server.text.trim());
    await p.setString('room', _room.text.trim());
    await p.setString('license', _license.text.trim());
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SenderPage(
        serverUrl: _server.text.trim(),
        room: _room.text.trim().isEmpty ? 'qa' : _room.text.trim(),
        licenseKey: _license.text.trim(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Nosmai WebRTC Bridge')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _server,
            decoration: const InputDecoration(
              labelText: 'Signalling server (ws://<mac-ip>:8080)',
              helperText: 'Use the computer’s Wi-Fi address. Start the server from example/server.',
            ),
          ),
          TextField(controller: _room, decoration: const InputDecoration(labelText: 'Room')),
          TextField(
            controller: _license,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Nosmai licence key (bound to the app id)'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _open,
            icon: const Icon(Icons.videocam),
            label: const Text('Open sender (go live)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openViewer,
            icon: const Icon(Icons.visibility),
            label: const Text('Open viewer (watch live, no licence needed)'),
          ),
        ]),
      );
}

/// Sender: Nosmai owns camera + preview; the bridge turns Nosmai's output into a flutter_webrtc
/// track; THIS file owns the RTCPeerConnection and the signalling (a plain WebSocket).
class SenderPage extends StatefulWidget {
  const SenderPage({super.key, required this.serverUrl, required this.room, required this.licenseKey});
  final String serverUrl;
  final String room;
  final String licenseKey;

  @override
  State<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends State<SenderPage> {
  bool _ready = false;
  bool _cameraReady = false;
  bool _changingBroadcast = false;
  bool _live = false;
  bool _front = true;
  bool _streamMirror = false;
  String _status = 'Starting Nosmai...';

  RTCPeerConnection? _pc;
  MediaStream? _audioStream;
  WebSocket? _ws;
  Timer? _statsTimer;
  StreamSubscription<NosmaiFrameStats>? _frameSub;

  // Live numbers shown in the banner.
  double _sendFps = 0, _nosmaiFps = 0;
  double? _viewerFps;
  String _sendDetail = '';
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteSet = false;
  int _prevBytes = -1;
  DateTime? _prevAt;

  @override
  void initState() {
    super.initState();
    _initNosmai();
  }

  Future<void> _initNosmai() async {
    try {
      final perms = await [Permission.camera, Permission.microphone].request();
      if (!mounted) return;
      if (perms.values.any((s) => !s.isGranted)) {
        setState(() => _status = 'Camera and microphone permission required');
        return;
      }
      // Register WebRTC's Android graphics context before opening the Nosmai camera.
      final handle = await NosmaiWebRtcBridge.registerShareContext();
      if (!mounted) return;
      if (handle == null) {
        setState(() => _status = 'Could not prepare the WebRTC camera');
        return;
      }
      if (!await NosmaiFlutter.initialize(widget.licenseKey)) {
        throw StateError('Check the Nosmai license for this application ID.');
      }
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Starting camera...';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Nosmai init failed: $e');
    }
  }

  // ---- live ---------------------------------------------------------------------------------
  Future<void> _toggleBroadcast() async {
    if (_changingBroadcast || (!_live && !_cameraReady)) return;
    setState(() => _changingBroadcast = true);
    try {
      if (_live) {
        await _stopLive();
      } else {
        await _goLive();
      }
    } finally {
      if (mounted) setState(() => _changingBroadcast = false);
    }
  }

  Future<void> _goLive() async {
    try {
      // Signalling first: if the server is unreachable, fail before minting a track.
      setState(() => _status = 'Connecting to ${widget.serverUrl}...');
      final ws = await connectSignalling(widget.serverUrl, onRetry: (n, e) {
        if (mounted) setState(() => _status = 'Signalling retry $n: $e');
      });
      _ws = ws;

      setState(() => _status = 'Creating track...');
      // The viewer must see what the sender sees on screen; see _streamMirror above.
      await NosmaiWebRtcBridge.setMirror(_streamMirror);
      final v = await NosmaiWebRtcBridge.createVideoTrack();

      _audioStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});

      final pc = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ],
      });
      _pc = pc;
      _remoteSet = false;
      _pendingCandidates.clear();
      pc.onIceCandidate = (c) {
        _send({'type': 'candidate', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      };
      pc.onConnectionState = (s) {
        if (mounted) setState(() => _status = 'Peer: ${s.name}');
      };

      await pc.addTrack(v.track, v.stream);
      for (final t in _audioStream!.getAudioTracks()) {
        await pc.addTrack(t, _audioStream!);
      }

      // The socket buffers anything received before this listen.
      ws.listen(_onSignal, onDone: () {
        if (mounted && _live) setState(() => _status = 'Signalling closed');
      });
      _send({'type': 'join', 'room': widget.room, 'role': 'publisher'});

      setState(() {
        _live = true;
        _status = 'Waiting for viewer...';
      });
      _frameSub = NosmaiWebRtcBridge.frameStats().listen((s) {
        if (mounted) setState(() => _nosmaiFps = s.nosmaiOutputFps);
      });
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
    } catch (e, st) {
      debugPrint('[example/sender] Go Live failed: $e\n$st');
      setState(() => _status = 'Go Live failed: $e');
      await _stopLive(keepStatus: true);
    }
  }

  void _send(Map<String, dynamic> m) => _ws?.add(jsonEncode(m));

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final pc = _pc;
    if (pc == null) return;
    switch (m['type']) {
      case 'viewer-joined':
        setState(() => _status = 'Viewer joined, sending offer');
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        _send({'type': 'offer', 'sdp': offer.sdp});
      case 'answer':
        await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, 'answer'));
        _remoteSet = true;
        for (final c in _pendingCandidates) {
          await pc.addCandidate(c);
        }
        _pendingCandidates.clear();
      case 'candidate':
        final c = RTCIceCandidate(m['candidate'] as String?, m['sdpMid'] as String?, m['sdpMLineIndex'] as int?);
        if (_remoteSet) {
          await pc.addCandidate(c);
        } else {
          _pendingCandidates.add(c);
        }
      case 'viewer-stats':
        setState(() => _viewerFps = (m['renderedFps'] as num?)?.toDouble());
      case 'viewer-left':
        setState(() {
          _viewerFps = null;
          _status = 'Viewer left';
        });
    }
  }

  // Static so a hot reload into a live session initializes it (new instance fields would not be).
  static int _pollN = 0;

  Future<void> _pollStats() async {
    final pc = _pc;
    if (pc == null) return;
    final n = ++_pollN;
    if (n % 5 == 0) debugPrint('[example/stats] poll $n: getStats...');
    final reports = await pc.getStats();
    if (n % 5 == 0) {
      final c = await NosmaiWebRtcBridge.getCounters();
      final out = reports.where((r) => r.type == 'outbound-rtp').map((r) =>
          '${r.values['kind'] ?? r.values['mediaType']}:${r.values['framesPerSecond'] ?? '-'}fps,'
          '${r.values['frameWidth'] ?? '-'}x${r.values['frameHeight'] ?? '-'},'
          'sent=${r.values['framesSent'] ?? r.values['packetsSent']},enc=${r.values['encoderImplementation'] ?? '-'}');
      debugPrint('[example/stats] bridge nosmai=${c?.nosmaiFrames} pushed=${c?.pushedFrames} '
          'dropped=${c?.droppedFrames} ${c?.width}x${c?.height} | nosmaiFps=${_nosmaiFps.toStringAsFixed(1)} '
          'viewer=${_viewerFps?.toStringAsFixed(1)} | ${out.join(' ; ')}');
    }
    for (final r in reports) {
      if (r.type == 'outbound-rtp' && r.values['kind'] == 'video') {
        final v = r.values;
        final bytes = (v['bytesSent'] as num?)?.toInt() ?? 0;
        final now = DateTime.now();
        double? kbps;
        if (_prevBytes >= 0 && _prevAt != null) {
          final dt = now.difference(_prevAt!).inMicroseconds / 1e6;
          if (dt > 0) kbps = (bytes - _prevBytes) * 8 / dt / 1000;
        }
        _prevBytes = bytes;
        _prevAt = now;
        if (!mounted) return;
        if (now.second % 5 == 0) {
          debugPrint('[example/stats] send=${(v['framesPerSecond'] as num?)?.toStringAsFixed(1)}fps '
              'nosmai=${_nosmaiFps.toStringAsFixed(1)}fps viewer=${_viewerFps?.toStringAsFixed(1)}fps '
              '${v['frameWidth']}x${v['frameHeight']} ${kbps?.toStringAsFixed(0)}kbps '
              'enc=${v['encoderImplementation']} limit=${v['qualityLimitationReason']} mirror=$_streamMirror');
        }
        setState(() {
          _sendFps = (v['framesPerSecond'] as num?)?.toDouble() ?? 0;
          _sendDetail = '${v['frameWidth'] ?? '-'}x${v['frameHeight'] ?? '-'}  '
              '${kbps?.toStringAsFixed(0) ?? '-'} kbps  '
              '${v['encoderImplementation'] ?? ''}  limit=${v['qualityLimitationReason'] ?? '-'}';
        });
      }
    }
  }

  Future<void> _stopLive({bool keepStatus = false}) async {
    _statsTimer?.cancel();
    await _frameSub?.cancel();
    // Order matters: stop the Nosmai producer first, then the peer connection and socket.
    await NosmaiWebRtcBridge.stopStreaming();
    await _pc?.close();
    _pc = null;
    await _ws?.close();
    _ws = null;
    for (final t in _audioStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _audioStream?.dispose();
    _audioStream = null;
    _prevBytes = -1;
    if (mounted) {
      setState(() {
        _live = false;
        _viewerFps = null;
        _sendFps = 0;
        if (!keepStatus) _status = 'Stopped';
      });
    }
  }

  Future<void> _switchCamera() async {
    await NosmaiFlutter.instance.switchCamera();
    _front = !_front;
    _streamMirror = false;
    await NosmaiWebRtcBridge.setMirror(_streamMirror);
    setState(() {});
  }

  @override
  void dispose() {
    _stopLive();
    super.dispose();
  }

  // ---- UI -----------------------------------------------------------------------------------
  String? _lastLogged;

  @override
  Widget build(BuildContext context) {
    if (_lastLogged != _status) {
      _lastLogged = _status;
      debugPrint('[example/sender] $_status');
    }
    final banner = _live
        ? 'SEND ${_sendFps.toStringAsFixed(1)} fps | VIEWER GETS ${_viewerFps?.toStringAsFixed(1) ?? '-'} fps'
        : 'Not live';
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: _ready
                ? NosmaiCameraPreview(
                    onInitialized: () {
                      if (!mounted) return;
                      setState(() {
                        _cameraReady = true;
                        if (!_live) _status = 'Camera ready. Tap Go Live to publish.';
                      });
                    },
                    onError: (message) {
                      if (mounted) setState(() { _cameraReady = false; _status = message; });
                    },
                  )
                : Center(child: Text(_status)),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(children: [
              Container(
                width: double.infinity,
                color: const Color(0xCC0B3D91),
                padding: const EdgeInsets.all(8),
                child: Text(banner,
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              if (_live)
                Container(
                  width: double.infinity,
                  color: Colors.black54,
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Nosmai out ${_nosmaiFps.toStringAsFixed(1)} fps\n$_sendDetail',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
            ]),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_status, style: const TextStyle(color: Color(0xFFB0E0FF))),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: (_live || _cameraReady) && !_changingBroadcast ? _toggleBroadcast : null,
                      child: Text(_live ? 'Stop Live' : 'Go Live'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _ready
                          ? () => showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) => const EffectsSheet(),
                              )
                          : null,
                      child: const Text('Effects'),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _ready ? _switchCamera : null,
                      child: Text(_front ? 'Front' : 'Back'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _ready
                          ? () async {
                              _streamMirror = !_streamMirror;
                              await NosmaiWebRtcBridge.setMirror(_streamMirror);
                              setState(() {});
                            }
                          : null,
                      child: Text('Mirror ${_streamMirror ? 'ON' : 'OFF'}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _ready ? () => NosmaiFlutter.instance.removeAllFilters() : null,
                      child: const Text('Clear'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
