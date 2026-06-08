import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/protocol/enums.dart';
import '../../state/device_controller.dart';
import '../../state/settings_controller.dart';
import '../widgets/labeled_slider.dart';
import '../widgets/preset_bar.dart';
import '../widgets/ptz_joystick.dart';
import 'panel_scaffold.dart';

/// PTZ joystick, arrows, recenter, go-to, live position, presets, zoom, mode.
class ControlPanel extends StatefulWidget {
  const ControlPanel({super.key});

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DeviceController>();
    final enabled = controller.controlsEnabled;
    final s = controller.state;

    return PanelBody(
      title: 'Control',
      children: [
        if (!enabled) const _UngateHint(),
        if (s.motorWedgeWarning) _WedgeWarning(onDismiss: controller.clearMotorWarning),

        PanelCard(
          title: 'Camera mode',
          subtitle: enabled ? null : 'Mode unknown until the camera stream is live.',
          // Empty selection while gated: don't assert "Standard" when the
          // device actually reports `startup` (real mode unknown).
          child: SegmentedButton<CameraMode>(
            emptySelectionAllowed: true,
            segments: const [
              ButtonSegment(value: CameraMode.standard, label: Text('Standard')),
              ButtonSegment(value: CameraMode.tracking, label: Text('Tracking')),
              ButtonSegment(value: CameraMode.privacy, label: Text('Privacy')),
            ],
            selected: (!enabled || s.mode == CameraMode.startup)
                ? <CameraMode>{}
                : {s.mode},
            onSelectionChanged:
                enabled ? (sel) => controller.setMode(sel.first) : null,
          ),
        ),

        PanelCard(
          title: 'Pan / Tilt',
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PtzJoystick(
                    enabled: enabled,
                    onDrive: controller.drive,
                    onStop: controller.stopDrive,
                  ),
                  const SizedBox(width: 24),
                  Expanded(child: _ArrowsAndReadout(enabled: enabled)),
                ],
              ),
            ],
          ),
        ),

        PanelCard(
          title: 'Presets',
          child: PresetBar(enabled: enabled),
        ),

        PanelCard(
          title: 'Zoom',
          subtitle: 'Digital zoom (100–150). Needs 2K/1080p/720p @30fps preview.',
          child: Builder(builder: (context) {
            final zoom = controller.device?.imageControl('zoomAbsolute');
            final gated = controller.zoomAvailable;
            return LabeledSlider(
              label: 'Zoom',
              value: (zoom?.value ?? 100).toDouble(),
              min: (zoom?.min ?? 100).toDouble(),
              max: (zoom?.max ?? 150).toDouble(),
              enabled: enabled && gated,
              disabledHint: gated
                  ? null
                  : 'Zoom needs 2K/1080p/720p @30fps preview (§4.6).',
              onChanged: (v) =>
                  controller.setImageControl('zoomAbsolute', v.round()),
            );
          }),
        ),
      ],
    );
  }

}

class _ArrowsAndReadout extends StatelessWidget {
  const _ArrowsAndReadout({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DeviceController>();
    final settings = context.watch<SettingsController>();
    final step = settings.stepDeg;
    final s = controller.state;

    Widget arrow(IconData icon, MotorAxis axis, double sign) =>
        IconButton.filledTonal(
          onPressed: enabled ? () => controller.step(axis, sign * step) : null,
          icon: Icon(icon),
        );

    return Column(
      children: [
        arrow(Icons.keyboard_arrow_up, MotorAxis.tilt, 1),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            arrow(Icons.keyboard_arrow_left, MotorAxis.pan, -1),
            IconButton.filledTonal(
              tooltip: 'Recenter',
              onPressed: enabled ? controller.recenter : null,
              icon: const Icon(Icons.center_focus_strong),
            ),
            arrow(Icons.keyboard_arrow_right, MotorAxis.pan, 1),
          ],
        ),
        arrow(Icons.keyboard_arrow_down, MotorAxis.tilt, -1),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Step '),
            DropdownButton<double>(
              value: settings.stepDeg,
              items: SettingsController.stepOptions
                  .map((v) => DropdownMenuItem(value: v, child: Text('${v.toInt()}°')))
                  .toList(),
              onChanged: (v) => v == null ? null : settings.setStep(v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Pan ${s.pan.toStringAsFixed(1)}°   Tilt ${s.tilt.toStringAsFixed(1)}°',
            style: Theme.of(context).textTheme.labelLarge),
      ],
    );
  }
}

class _UngateHint extends StatelessWidget {
  const _UngateHint();
  @override
  Widget build(BuildContext context) {
    final controller = context.read<DeviceController>();
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('Camera controls are inactive'),
        subtitle: const Text(
            'Controls activate once the camera is streaming video. Open the live '
            'preview here, or start the camera in your video app (Zoom/OBS).'),
        trailing: FilledButton.tonalIcon(
          onPressed: () => controller.connect(),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Reconnect'),
        ),
      ),
    );
  }
}

class _WedgeWarning extends StatelessWidget {
  const _WedgeWarning({required this.onDismiss});
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.warning_amber),
        title: const Text('Motor command rejected (out of range)'),
        subtitle: const Text(
            'If motion keeps failing, the camera may need to be unplugged/replugged.'),
        trailing: IconButton(
            onPressed: onDismiss, icon: const Icon(Icons.close)),
      ),
    );
  }
}
