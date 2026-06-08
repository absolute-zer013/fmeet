import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/protocol/enums.dart';
import '../../state/device_controller.dart';
import 'panel_scaffold.dart';

/// Tracking, gesture, focus-metering (AF-lock gated), flip, auto-rotate (§6).
class AiPanel extends StatelessWidget {
  const AiPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<DeviceController>();
    final enabled = c.controlsEnabled;
    final s = c.state;

    // Focus-metering requires focus Lock (AF off) — read the v4l2 focusAuto.
    final focusAuto = c.device?.imageControl('focusAuto');
    final afOn = (focusAuto?.value ?? 1) != 0;

    return PanelBody(
      title: 'AI',
      children: [
        if (!enabled) const GatingBanner(),
        PanelCard(
          title: 'Subject tracking',
          subtitle: 'Tracking is a camera mode (also on the Control panel).',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tracking'),
                // EMEET has no standalone tracking on/off command — "tracking"
                // IS the camera mode (09 01 01 00 = 01). Drive the mode directly.
                value: s.mode == CameraMode.tracking,
                onChanged: enabled
                    ? (v) => c.setMode(
                        v ? CameraMode.tracking : CameraMode.standard)
                    : null,
              ),
            ],
          ),
        ),
        PanelCard(
          title: 'Gesture control',
          subtitle: 'Enables the gesture flag on the camera. The PIXY only '
              'detects gestures while it is actively framing — turn Tracking on.',
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Gesture control'),
            value: s.gesture,
            onChanged: enabled ? c.setGesture : null,
          ),
        ),
        PanelCard(
          title: 'Focus / metering',
          subtitle: afOn
              ? 'Disabled while Auto Focus is on — set focus to Lock in the Image panel.'
              : 'Central · Face · Selected area',
          child: SegmentedButton<FocusMetering>(
            segments: const [
              ButtonSegment(value: FocusMetering.central, label: Text('Central')),
              ButtonSegment(value: FocusMetering.face, label: Text('Face')),
              ButtonSegment(
                  value: FocusMetering.selectedArea, label: Text('Area')),
            ],
            selected: {s.focusMetering},
            onSelectionChanged: (enabled && !afOn)
                ? (sel) => c.setFocusMetering(sel.first)
                : null,
          ),
        ),
        PanelCard(
          title: 'Orientation',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Flip vertical'),
                value: s.flipV,
                onChanged: enabled ? c.setFlipVertical : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Flip horizontal'),
                value: s.flipH,
                onChanged: enabled ? c.setFlipHorizontal : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-rotate when upside down'),
                value: s.autoRotate,
                onChanged: enabled ? c.setAutoRotate : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
