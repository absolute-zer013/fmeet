import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/device_controller.dart';
import '../../state/settings_controller.dart';

/// Preset slots: Initial / No.1-3 recall, save-current, editable local labels
/// (spec §6 control panel). Slot 0 = Initial, 1..3 = No.1..3.
class PresetBar extends StatelessWidget {
  const PresetBar({super.key, this.enabled = true});
  final bool enabled;

  static const List<int> slots = [0, 1, 2, 3];

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final controller = context.read<DeviceController>();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final slot in slots)
          _PresetChip(
            label: settings.presetLabel(slot),
            enabled: enabled,
            onRecall: () => controller.gotoPreset(slot),
            onSave: () async {
              final messenger = ScaffoldMessenger.of(context);
              await controller.savePreset(slot);
              messenger
                ..clearSnackBars()
                ..showSnackBar(SnackBar(
                    content: Text(
                        'Saved current position to "${settings.presetLabel(slot)}"'),
                    duration: const Duration(seconds: 2)));
            },
            onRename: () => _rename(context, settings, slot),
          ),
      ],
    );
  }

  Future<void> _rename(
      BuildContext context, SettingsController settings, int slot) async {
    final ctrl = TextEditingController(text: settings.presetLabel(slot));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename preset'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Label'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (result != null) await settings.setPresetLabel(slot, result);
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.enabled,
    required this.onRecall,
    required this.onSave,
    required this.onRename,
  });

  final String label;
  final bool enabled;
  final VoidCallback onRecall;
  final VoidCallback onSave;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: enabled ? onRecall : null,
            child: Text(label),
          ),
          IconButton(
            tooltip: 'Save current position',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: enabled ? onSave : null,
            icon: const Icon(Icons.save_alt),
          ),
          IconButton(
            tooltip: 'Rename',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onRename,
            icon: const Icon(Icons.edit),
          ),
        ],
      ),
    );
  }
}
