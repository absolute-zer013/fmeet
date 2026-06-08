import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/protocol/enums.dart';
import '../../state/device_controller.dart';
import 'panel_scaffold.dart';

/// Audio mode selector: Live / Noise-Canceling / Original (spec §6).
class AudioPanel extends StatelessWidget {
  const AudioPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<DeviceController>();
    final enabled = c.controlsEnabled;
    final s = c.state;

    return PanelBody(
      title: 'Audio',
      children: [
        if (!enabled) const GatingBanner(),
        PanelCard(
          title: 'Audio mode',
          subtitle:
              'Live keeps ambience · Noise-Canceling isolates speech · Original is unprocessed.',
          child: SegmentedButton<AudioMode>(
            segments: const [
              ButtonSegment(value: AudioMode.live, label: Text('Live')),
              ButtonSegment(
                  value: AudioMode.noiseCanceling, label: Text('Noise-Cancel')),
              ButtonSegment(value: AudioMode.original, label: Text('Original')),
            ],
            selected: {s.audioMode},
            onSelectionChanged:
                enabled ? (sel) => c.setAudioMode(sel.first) : null,
          ),
        ),
      ],
    );
  }
}
