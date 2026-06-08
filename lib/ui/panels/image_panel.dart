import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/stream/capture_resolution.dart';
import '../../core/v4l2/v4l2_controls.dart';
import '../../state/device_controller.dart';
import '../../state/settings_controller.dart';
import '../widgets/labeled_slider.dart';
import 'panel_scaffold.dart';

/// Image / exposure / focus / WB controls — all via v4l2 (spec §6).
class ImagePanel extends StatefulWidget {
  const ImagePanel({super.key});

  @override
  State<ImagePanel> createState() => _ImagePanelState();
}

class _ImagePanelState extends State<ImagePanel> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    await context.read<DeviceController>().device?.refreshImageControls();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DeviceController>();
    final enabled = controller.isConnected && controller.v4l2 != null;

    if (!enabled) {
      return const PanelBody(title: 'Image', children: [
        Card(
            child: ListTile(
                leading: Icon(Icons.image_not_supported),
                title: Text('No V4L2 device'),
                subtitle: Text('Connect a PIXY to adjust image controls.'))),
      ]);
    }

    return PanelBody(
      title: 'Image',
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reload from device'),
          ),
        ),
        _resolutionSection(controller, context.watch<SettingsController>()),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _basicSection(controller),
          _antiFlickerSection(controller),
          _whiteBalanceSection(controller),
          _exposureSection(controller),
          _focusSection(controller),
        ],
      ],
    );
  }

  // ---- sections --------------------------------------------------------------

  Widget _resolutionSection(DeviceController c, SettingsController s) {
    final current = s.captureResolution;
    final fps = s.captureFps;
    return PanelCard(
      title: 'Picture quality',
      subtitle: 'Resolution for PixyControl\'s stream/preview. '
          'Digital zoom needs 2K/1080p/720p; 60fps only at 1080p/720p.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<CaptureResolution>(
            segments: CaptureResolution.values
                .map((r) => ButtonSegment(value: r, label: Text(r.label)))
                .toList(),
            selected: {current},
            showSelectedIcon: false,
            onSelectionChanged: (sel) => c.setCaptureResolution(sel.first),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Frame rate  '),
              SegmentedButton<int>(
                segments: [
                  const ButtonSegment(value: 30, label: Text('30fps')),
                  ButtonSegment(
                    value: 60,
                    label: const Text('60fps'),
                    enabled: current.supports60,
                  ),
                ],
                selected: {fps},
                showSelectedIcon: false,
                onSelectionChanged: (sel) => c.setCaptureFps(sel.first),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${current.width}×${current.height} @ ${fps}fps',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _basicSection(DeviceController c) {
    return PanelCard(
      title: 'Picture',
      trailing: _restoreButton(c, [
        'brightness',
        'contrast',
        'saturation',
        'tone',
        'sharpness',
        'gain',
      ]),
      child: Column(
        children: [
          _slider(c, 'Brightness', 'brightness'),
          _slider(c, 'Contrast', 'contrast'),
          _slider(c, 'Saturation', 'saturation'),
          _slider(c, 'Tone', 'tone'),
          _slider(c, 'Sharpness', 'sharpness'),
          _slider(c, 'ISO / Gain', 'gain'),
        ],
      ),
    );
  }

  Widget _antiFlickerSection(DeviceController c) {
    final ctrl = c.device?.imageControl('powerLineFrequency');
    if (ctrl == null) return const SizedBox.shrink();
    // menu: 0 disabled, 1 50Hz, 2 60Hz
    return PanelCard(
      title: 'Anti-flicker',
      child: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 0, label: Text('Off')),
          ButtonSegment(value: 1, label: Text('50 Hz')),
          ButtonSegment(value: 2, label: Text('60 Hz')),
        ],
        selected: {ctrl.value.clamp(0, 2)},
        onSelectionChanged: (sel) async {
          await c.setImageControl('powerLineFrequency', sel.first);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Widget _whiteBalanceSection(DeviceController c) {
    final auto = c.device?.imageControl('whiteBalanceAuto');
    final temp = c.device?.imageControl('whiteBalanceTemp');
    if (auto == null && temp == null) return const SizedBox.shrink();
    final awbOn = (auto?.value ?? 1) != 0;
    return PanelCard(
      title: 'White balance',
      child: Column(
        children: [
          if (auto != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto white balance'),
              value: awbOn,
              onChanged: (v) async {
                await c.setImageControl('whiteBalanceAuto', v ? 1 : 0);
                if (mounted) setState(() {});
              },
            ),
          if (temp != null)
            _slider(c, 'Temperature', 'whiteBalanceTemp',
                enabled: !awbOn,
                disabledHint: 'Turn off auto white balance to adjust.'),
        ],
      ),
    );
  }

  Widget _exposureSection(DeviceController c) {
    final auto = c.device?.imageControl('autoExposure');
    final time = c.device?.imageControl('exposureTime');
    if (auto == null && time == null) return const SizedBox.shrink();
    // `auto_exposure` is a MENU, not 1/8: on the PIXY it's min=0 max=3, where
    // 1 = Manual and 3 = Aperture Priority (auto, the device default). Use the
    // device's own values — the old hardcoded `8` clamped to 3 so the switch
    // never matched its own readback and appeared dead.
    const manualVal = 1;
    final autoVal =
        (auto?.defaultValue != null && auto!.defaultValue != manualVal)
            ? auto.defaultValue!
            : 3;
    final autoOn = (auto?.value ?? autoVal) != manualVal;
    return PanelCard(
      title: 'Exposure',
      child: Column(
        children: [
          if (auto != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto exposure'),
              value: autoOn,
              onChanged: (v) async {
                await c.setImageControl('autoExposure', v ? autoVal : manualVal);
                // exposure_time_absolute toggles its `inactive` flag with the
                // mode — re-enumerate so the slider's gating + live value update.
                await c.device?.refreshImageControls();
                if (mounted) setState(() {});
              },
            ),
          if (time != null)
            _slider(c, 'Exposure time', 'exposureTime',
                enabled: !autoOn && !time.isInactive,
                disabledHint: 'Switch to manual exposure to adjust.'),
        ],
      ),
    );
  }

  Widget _focusSection(DeviceController c) {
    final auto = c.device?.imageControl('focusAuto');
    final focus = c.device?.imageControl('focusAbsolute');
    if (auto == null && focus == null) return const SizedBox.shrink();
    final afOn = (auto?.value ?? 1) != 0;
    return PanelCard(
      title: 'Focus',
      subtitle: 'Focus-metering (AI panel) is only available in Lock mode.',
      child: Column(
        children: [
          if (auto != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto focus'),
              subtitle: Text(afOn ? 'AF' : 'Lock'),
              value: afOn,
              onChanged: (v) async {
                await c.setImageControl('focusAuto', v ? 1 : 0);
                if (mounted) setState(() {});
              },
            ),
          if (focus != null)
            _slider(c, 'Focus', 'focusAbsolute',
                enabled: !afOn, disabledHint: 'Lock focus to adjust manually.'),
        ],
      ),
    );
  }

  // ---- helpers ---------------------------------------------------------------

  Widget _slider(DeviceController c, String label, String logical,
      {bool enabled = true, String? disabledHint}) {
    final V4l2Control? ctrl = c.device?.imageControl(logical);
    if (ctrl == null) return const SizedBox.shrink();
    return LabeledSlider(
      label: label,
      value: ctrl.value.toDouble(),
      min: (ctrl.min ?? 0).toDouble(),
      max: (ctrl.max ?? 255).toDouble(),
      enabled: enabled && !ctrl.isReadOnly,
      disabledHint: disabledHint,
      onChanged: (v) async {
        await c.setImageControl(logical, v.round());
      },
    );
  }

  Widget _restoreButton(DeviceController c, List<String> logicals) {
    return TextButton.icon(
      onPressed: () async {
        for (final l in logicals) {
          final ctrl = c.device?.imageControl(l);
          if (ctrl?.defaultValue != null) {
            await c.setImageControl(l, ctrl!.defaultValue!);
          }
        }
        if (mounted) setState(() {});
      },
      icon: const Icon(Icons.restore, size: 18),
      label: const Text('Defaults'),
    );
  }
}
