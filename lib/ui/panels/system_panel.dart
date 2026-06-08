import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/protocol/enums.dart';
import '../../state/device_controller.dart';
import 'panel_scaffold.dart';

/// udev rule shipped with the app (§4.3). The 70- prefix sorts before
/// 73-seat-late.rules so uaccess tagging is applied.
const String kUdevRuleName = '70-emeet-pixy.rules';
const String kUdevRule =
    'KERNEL=="hidraw*", ATTRS{idVendor}=="328f", ATTRS{idProduct}=="00c0", '
    'MODE="0660", TAG+="uaccess"\n';

/// Privacy timer, device info, permissions helper, about (spec §6).
class SystemPanel extends StatefulWidget {
  const SystemPanel({super.key});

  @override
  State<SystemPanel> createState() => _SystemPanelState();
}

class _SystemPanelState extends State<SystemPanel> {
  String? _installMsg;
  bool _installing = false;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<DeviceController>();
    final s = c.state;
    final enabled = c.controlsEnabled;

    return PanelBody(
      title: 'System',
      children: [
        PanelCard(
          title: 'Auto-privacy timer',
          subtitle: 'Blank the lens automatically after inactivity.',
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 10, label: Text('10s')),
              ButtonSegment(value: 60, label: Text('1 min')),
              ButtonSegment(value: 900, label: Text('15 min')),
              ButtonSegment(value: PrivacyTimeout.never, label: Text('Never')),
            ],
            selected: {s.privacyTimeoutSec},
            onSelectionChanged:
                enabled ? (sel) => c.setPrivacyTimer(sel.first) : null,
          ),
        ),
        PanelCard(
          title: 'Device info',
          child: Column(
            children: [
              _info('Model', 'EMEET PIXY (328f:00c0)'),
              _info('Serial', s.serial ?? '—'),
              _info('Control node', s.hidrawPath ?? '—'),
              _info('Video node', s.videoNode ?? '—'),
            ],
          ),
        ),
        PanelCard(
          title: 'Permissions',
          subtitle:
              'HID control needs access to the PIXY hidraw node. Installs $kUdevRuleName.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (c.connection == PixyConnectionState.needsPermission)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Permission to the hidraw node is missing.',
                    style: TextStyle(color: Colors.amber),
                  ),
                ),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _installing ? null : _installUdev,
                    icon: _installing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.shield),
                    label: const Text('Install udev rule'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () =>
                        Clipboard.setData(const ClipboardData(text: kUdevRule)),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy rule'),
                  ),
                  const SizedBox(width: 12),
                  // Re-runs discovery + permission precheck so a freshly applied
                  // rule (after replug) clears the needs-permission state.
                  TextButton.icon(
                    onPressed: () => c.connect(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reconnect now'),
                  ),
                ],
              ),
              if (_installMsg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_installMsg!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
        const _AboutCard(),
      ],
    );
  }

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 120,
                child: Text(k,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.outline))),
            Expanded(child: SelectableText(v)),
          ],
        ),
      );

  /// Escalate with pkexec to install the udev rule, reload, and trigger.
  ///
  /// Security (privesc-hardened):
  /// - The installer script is staged in a fresh `mkdtemp` directory (mode
  ///   0700, random name) so no other non-root user can predict, pre-create, or
  ///   swap it between staging and the root execution (TOCTOU).
  /// - The rule content is embedded literally in the script via a quoted
  ///   heredoc — never read back from an attacker-swappable file by root.
  /// - pkexec and every command the root script runs use absolute paths, so a
  ///   hostile `$PATH` can't redirect them.
  Future<void> _installUdev() async {
    setState(() {
      _installing = true;
      _installMsg = null;
    });
    Directory? stage;
    try {
      // mkdtemp -> 0700, unpredictable name; only this user (and root) can touch it.
      stage = await Directory.systemTemp.createTemp('pixyctl_udev_');
      final script = File('${stage.path}/install.sh');
      await script.writeAsString(_installerScript);

      const pkexec = '/usr/bin/pkexec';
      if (!await File(pkexec).exists()) {
        setState(() => _installMsg =
            'pkexec not found at $pkexec. Use "Copy rule" and install manually '
            'into /etc/udev/rules.d/.');
        return;
      }
      final res = await Process.run(pkexec, ['/bin/sh', script.path]);
      if (!mounted) return;
      if (res.exitCode == 0) {
        setState(() => _installMsg =
            'Installed. Unplug and replug the PIXY, then reconnect.');
      } else {
        setState(() => _installMsg =
            'Install failed (exit ${res.exitCode}). Use "Copy rule" and install '
            'the rule manually into /etc/udev/rules.d/.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _installMsg =
            'Could not run the installer ($e). Copy the rule and install manually.');
      }
    } finally {
      // Best-effort cleanup of the staging dir.
      try {
        await stage?.delete(recursive: true);
      } catch (_) {}
      if (mounted) setState(() => _installing = false);
    }
  }

  /// Self-contained root installer. Rule text is written by the script itself
  /// (quoted heredoc) so root never copies an externally-supplied file.
  static const String _installerScript = '''
#!/bin/sh
set -eu
/usr/bin/mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/$kUdevRuleName <<'RULE'
$kUdevRule
RULE
/usr/bin/udevadm control --reload-rules
/usr/bin/udevadm trigger --subsystem-match=hidraw
''';
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();
  @override
  Widget build(BuildContext context) {
    return const PanelCard(
      title: 'About',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PixyControl — native Linux control for the EMEET PIXY.'),
          SizedBox(height: 6),
          Text('Protocol built on PixyBar (RoseWaveStudio, MIT) and extended '
              'through USB reverse engineering. MIT licensed.'),
        ],
      ),
    );
  }
}
