import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/protocol/frames.dart';
import '../../state/device_controller.dart';
import 'panel_scaffold.dart';

/// Developer aid: live decoded frame log + a raw send box (spec §6).
class DebugPanel extends StatefulWidget {
  const DebugPanel({super.key});

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  final List<String> _log = [];
  final _headerCtrl = TextEditingController(text: '09 03 01 14');
  final _payloadCtrl = TextEditingController();
  Stream<PixyFrame>? _boundStream;

  static const int _maxLog = 300;

  StreamSubscription<PixyFrame>? _sub;

  void _bind(DeviceController c) {
    final stream = c.frameStream;
    if (identical(stream, _boundStream)) return;
    _boundStream = stream;
    _sub?.cancel();
    _sub = stream?.listen(_onFrame);
  }

  void _onFrame(PixyFrame f) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, _decode(f));
      if (_log.length > _maxLog) _log.removeLast();
    });
  }

  String _decode(PixyFrame f) {
    final dir = f.isResponse ? '<-' : '->';
    final pl = f.payload
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return '$dir g=${_h(f.group)} ch=${_h(f.channel)} sub=${_h(f.sub)} '
        'len=${f.length} [${pl.isEmpty ? '-' : pl}]';
  }

  String _h(int v) => '0x${v.toRadixString(16).padLeft(2, '0')}';

  @override
  void dispose() {
    _sub?.cancel();
    _headerCtrl.dispose();
    _payloadCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<DeviceController>();
    _bind(c);

    return PanelBody(
      title: 'Debug',
      children: [
        PanelCard(
          title: 'Raw send',
          subtitle: 'Header is 4 hex bytes (e.g. 09 03 01 14). Payload optional.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _headerCtrl,
                decoration: const InputDecoration(
                    labelText: 'Header (4 bytes hex)', isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _payloadCtrl,
                decoration: const InputDecoration(
                    labelText: 'Payload (hex bytes, optional)', isDense: true),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: c.isConnected ? () => _send(c) : null,
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
        ),
        PanelCard(
          title: 'Frame log',
          trailing: IconButton(
            tooltip: 'Clear',
            onPressed: () => setState(_log.clear),
            icon: const Icon(Icons.delete_sweep),
          ),
          child: Container(
            // Responsive: ~40% of window height, clamped, instead of a fixed 360.
            height: (MediaQuery.sizeOf(context).height * 0.4).clamp(180.0, 480.0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: _log.isEmpty
                ? const Center(child: Text('No frames yet.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Text(
                      _log[i],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  void _send(DeviceController c) {
    final messenger = ScaffoldMessenger.of(context);
    void warn(String m) =>
        messenger.showSnackBar(SnackBar(content: Text(m)));

    final header = _parseHex(_headerCtrl.text);
    final payload = _parseHex(_payloadCtrl.text);
    if (header.length != 4) {
      warn('Header must be exactly 4 hex bytes.');
      return;
    }
    if (payload.length > kMaxPayload) {
      warn('Payload too long: max $kMaxPayload bytes per report.');
      return;
    }
    try {
      c.sendRaw(header, payload);
    } catch (e) {
      warn('Send failed: $e');
    }
  }

  List<int> _parseHex(String s) => s
      .trim()
      .split(RegExp(r'[\s,]+'))
      .where((p) => p.isNotEmpty)
      .map((p) => int.tryParse(p, radix: 16) ?? 0)
      .toList();
}
