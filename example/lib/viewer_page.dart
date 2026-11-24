import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'main.dart' show connectSignalling;

/// Viewer: joins the room as `viewer`, answers the publisher's offer and renders the remote video.
/// Reports its decoded fps back over signalling so the sender banner shows `VIEWER GETS y fps`.
/// No Nosmai SDK or licence is needed here.
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.serverUrl, required this.room});
  final String serverUrl;
  final String room;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final _renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  Timer? _statsTimer;
  final List<RTCIceCandidate> _pending = [];
  bool _remoteSet = false;
  String _status = 'Connecting...';
  double _fps = 0;
  String _detail = '';
  int _prevFrames = -1;
  int _prevBytes = 0;
  DateTime? _prevAt;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _renderer.initialize();
      final ws = await connectSignalling(widget.serverUrl, onRetry: (n, e) {
        if (mounted) setState(() => _status = 'Signalling retry $n: $e');
      });
      _ws = ws;
      ws.listen(_onSignal, onDone: () {
        if (mounted) setState(() => _status = 'Signalling closed');
      });
      _send({'type': 'join', 'room': widget.room, 'role': 'viewer'});
      setState(() => _status = 'Waiting for the sender to go live...');
    } catch (e) {
      setState(() => _status = 'Connect failed: $e');
    }
  }

  void _send(Map<String, dynamic> m) => _ws?.add(jsonEncode(m));

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['type']) {
      case 'offer':
        await _onOffer(m['sdp'] as String);
      case 'candidate':
        final c = RTCIceCandidate(m['candidate'] as String?, m['sdpMid'] as String?, m['sdpMLineIndex'] as int?);
        if (_pc != null && _remoteSet) {
          await _pc!.addCandidate(c);
        } else {
          _pending.add(c);
        }
      case 'publisher-left':
        setState(() {
          _status = 'Sender left';
          _fps = 0;
        });
        await _closePc();
    }
  }

  Future<void> _onOffer(String sdp) async {
    await _closePc();
    final pc = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ],
    });
    _pc = pc;
    pc.onIceCandidate = (c) => _send(
        {'type': 'candidate', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    pc.onConnectionState = (s) {
      if (mounted) setState(() => _status = 'Peer: ${s.name}');
    };
    pc.onTrack = (e) {
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        setState(() => _renderer.srcObject = e.streams.first);
      }
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteSet = true;
    for (final c in _pending) {
      await pc.addCandidate(c);
    }
    _pending.clear();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _send({'type': 'answer', 'sdp': answer.sdp});
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
  }

  Future<void> _pollStats() async {
    final pc = _pc;
    if (pc == null) return;
    for (final r in await pc.getStats()) {
      if (r.type == 'inbound-rtp' && r.values['kind'] == 'video') {
        final v = r.values;
        final frames = (v['framesDecoded'] as num?)?.toInt() ?? 0;
        final bytes = (v['bytesReceived'] as num?)?.toInt() ?? 0;
        final now = DateTime.now();
        if (_prevFrames >= 0 && _prevAt != null) {
          final dt = now.difference(_prevAt!).inMicroseconds / 1e6;
          if (dt > 0) {
            final fps = (frames - _prevFrames) / dt;
            final kbps = (bytes - _prevBytes) * 8 / dt / 1000;
            _send({
              'type': 'viewer-stats',
              'decodedFps': fps,
              'renderedFps': fps,
              'w': (v['frameWidth'] as num?)?.toInt() ?? 0,
              'h': (v['frameHeight'] as num?)?.toInt() ?? 0,
              'kbps': kbps,
              'freezes': (v['freezeCount'] as num?)?.toInt() ?? 0,
            });
            if (mounted) {
              setState(() {
                _fps = fps;
                _detail = '${v['frameWidth'] ?? '-'}x${v['frameHeight'] ?? '-'}  ${kbps.toStringAsFixed(0)} kbps  '
                    'lost=${v['packetsLost'] ?? 0}  freezes=${v['freezeCount'] ?? 0}';
              });
            }
          }
        }
        _prevFrames = frames;
        _prevBytes = bytes;
        _prevAt = now;
      }
    }
  }

  Future<void> _closePc() async {
    _statsTimer?.cancel();
    _remoteSet = false;
    _pending.clear();
    _prevFrames = -1;
    _prevAt = null;
    _renderer.srcObject = null;
    await _pc?.close();
    _pc = null;
  }

  @override
  void dispose() {
    _closePc();
    _ws?.close();
    _renderer.dispose();
    super.dispose();
  }

  String? _lastLogged;

  @override
  Widget build(BuildContext context) {
    if (_lastLogged != _status) {
      _lastLogged = _status;
      debugPrint('[example/viewer] $_status');
    }
    return _scaffold();
  }

  Widget _scaffold() => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: RTCVideoView(_renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
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
                  child: Text('RECEIVING ${_fps.toStringAsFixed(1)} fps',
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                if (_detail.isNotEmpty)
                  Container(
                    width: double.infinity,
                    color: Colors.black54,
                    padding: const EdgeInsets.all(8),
                    child: Text(_detail,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace')),
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
                child: Text(_status, style: const TextStyle(color: Color(0xFFB0E0FF))),
              ),
            ),
          ]),
        ),
      );
}
