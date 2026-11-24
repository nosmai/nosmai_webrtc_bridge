import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

/// Bottom sheet to change Nosmai effects while live. Everything here only touches Nosmai: the
/// bridge streams whatever Nosmai renders, so the viewer sees each change on the next frame.
class EffectsSheet extends StatefulWidget {
  const EffectsSheet({super.key});

  @override
  State<EffectsSheet> createState() => _EffectsSheetState();
}

class _EffectsSheetState extends State<EffectsSheet> {
  final _sdk = NosmaiFlutter.instance;
  double _smooth = 0, _whiten = 0, _bright = 0;
  List<NosmaiFilter>? _effects;
  String? _error;
  String? _busyId;
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _sdk.getCloudFilters(filterType: NosmaiCloudFilterType.effects, page: 1, limit: 30);
      if (mounted) setState(() => _effects = list);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load cloud effects: $e');
    }
  }

  Future<void> _apply(NosmaiFilter f) async {
    setState(() {
      _busyId = f.id;
      _error = null;
    });
    try {
      final result = await _sdk.downloadCloudFilter(f.cloudIdentifier);
      final path = result['path'];
      if (path is! String || path.isEmpty || !await File(path).exists()) {
        throw StateError('Downloaded effect file is unavailable');
      }
      if (!await _sdk.applyEffect(path)) throw StateError('Nosmai rejected the effect');
      if (mounted) setState(() => _activeId = f.id);
    } catch (e) {
      if (mounted) setState(() => _error = '${f.displayName}: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Widget _slider(String label, double value, double min, double max, Future<void> Function(double) apply,
          ValueChanged<double> onChanged) =>
      Row(children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
            onChangeEnd: (v) => apply(v),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
        Row(children: [
          const Expanded(child: Text('Effects', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          TextButton(
            onPressed: () async {
              await _sdk.removeAllFilters();
              setState(() {
                _smooth = _whiten = _bright = 0;
                _activeId = null;
              });
            },
            child: const Text('Clear all'),
          ),
        ]),
        _slider('Smoothing', _smooth, 0, 1, _sdk.applySkinSmoothing, (v) => setState(() => _smooth = v)),
        _slider('Whitening', _whiten, 0, 1, _sdk.applySkinWhitening, (v) => setState(() => _whiten = v)),
        _slider('Brightness', _bright, -1, 1, _sdk.applyBrightnessFilter, (v) => setState(() => _bright = v)),
        const Divider(),
        const Text('AR effects (cloud)', style: TextStyle(fontWeight: FontWeight.bold)),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        if (_effects == null && _error == null) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        for (final f in _effects ?? const <NosmaiFilter>[])
          ListTile(
            dense: true,
            title: Text(f.displayName),
            subtitle: Text(f.isDownloaded ? 'downloaded' : 'tap to download'),
            trailing: _busyId == f.id
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : (_activeId == f.id ? const Icon(Icons.check_circle, color: Colors.green) : null),
            onTap: _busyId == null ? () => _apply(f) : null,
          ),
      ]),
    );
  }
}
