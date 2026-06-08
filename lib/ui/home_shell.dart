import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol/enums.dart';
import '../state/device_controller.dart';
import '../state/settings_controller.dart';
import 'panels/ai_panel.dart';
import 'panels/audio_panel.dart';
import 'panels/control_panel.dart';
import 'panels/debug_panel.dart';
import 'panels/image_panel.dart';
import 'panels/system_panel.dart';
import 'widgets/connection_badge.dart';
import 'widgets/preview_view.dart';

/// Nav rail + panel content + persistent right-side preview pane (spec §6).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    (Icons.gamepad, 'Control'),
    (Icons.tune, 'Image'),
    (Icons.center_focus_strong, 'AI'),
    (Icons.graphic_eq, 'Audio'),
    (Icons.settings, 'System'),
    (Icons.bug_report, 'Debug'),
  ];

  @override
  void initState() {
    super.initState();
    // Auto-connect on launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DeviceController>().connect();
    });
  }

  Widget _panelFor(int i) => switch (i) {
        0 => const ControlPanel(),
        1 => const ImagePanel(),
        2 => const AiPanel(),
        3 => const AudioPanel(),
        4 => const SystemPanel(),
        _ => const DebugPanel(),
      };

  /// Deep-link from the connection badge to a remedy.
  void _onBadgeTap(PixyConnectionState s) {
    final controller = context.read<DeviceController>();
    if (s == PixyConnectionState.needsPermission) {
      setState(() => _index = 4); // System panel (permissions helper)
    } else if (s == PixyConnectionState.notFound ||
        s == PixyConnectionState.disconnected) {
      controller.connect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DeviceController>();
    final settings = context.watch<SettingsController>();
    final connecting =
        controller.connection == PixyConnectionState.connecting;

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            connecting: connecting,
            connected: controller.isConnected,
            darkMode: settings.darkMode,
            onBadgeTap: _onBadgeTap,
            onToggleTheme: () => settings.setDarkMode(!settings.darkMode),
            onConnect: () => controller.connect(),
            onDisconnect: () => controller.disconnect(),
          ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Collapse the preview pane on narrow windows so the control
                // panel (and its fixed-width joystick) don't overflow.
                final showPreview = constraints.maxWidth >= 900;
                return Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final (icon, label) in _destinations)
                          NavigationRailDestination(
                            icon: Icon(icon),
                            label: Text(label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 3,
                      child: _panelFor(_index),
                    ),
                    if (showPreview) ...[
                      const VerticalDivider(width: 1),
                      // Persistent preview pane across all panels.
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: PreviewView()),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.connecting,
    required this.connected,
    required this.darkMode,
    required this.onBadgeTap,
    required this.onToggleTheme,
    required this.onConnect,
    required this.onDisconnect,
  });

  final bool connecting;
  final bool connected;
  final bool darkMode;
  final void Function(PixyConnectionState) onBadgeTap;
  final VoidCallback onToggleTheme;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.videocam, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Text('PixyControl',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 16),
          ConnectionBadge(onTap: onBadgeTap),
          const Spacer(),
          IconButton(
            tooltip: darkMode ? 'Light theme' : 'Dark theme',
            onPressed: onToggleTheme,
            icon: Icon(darkMode ? Icons.light_mode : Icons.dark_mode),
          ),
          const SizedBox(width: 8),
          if (connected)
            OutlinedButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect'),
            )
          else
            FilledButton.icon(
              onPressed: connecting ? null : onConnect,
              icon: connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.usb, size: 18),
              label: Text(connecting ? 'Searching…' : 'Connect'),
            ),
        ],
      ),
    );
  }
}
