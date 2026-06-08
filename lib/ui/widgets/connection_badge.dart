import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/protocol/enums.dart';
import '../../state/device_controller.dart';

/// Connection status pill (spec §6 home shell). Distinguished by icon + label +
/// theme-token color (not color alone), announced to screen readers as a live
/// region. Tappable when there's a remedy (e.g. needs-permission → System).
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key, this.onTap});

  /// Invoked with the current state when the badge is actionable (tapped).
  final void Function(PixyConnectionState state)? onTap;

  @override
  Widget build(BuildContext context) {
    // Select only `connection` so motor/preview/image notifications don't rebuild
    // the badge.
    final connection = context
        .select<DeviceController, PixyConnectionState>((c) => c.connection);
    final spec = _describe(context, connection);
    final actionable = onTap != null && spec.actionHint != null;

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: spec.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: spec.fg.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spec.busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: spec.fg),
            )
          else
            Icon(spec.icon, size: 16, color: spec.fg),
          const SizedBox(width: 7),
          Text(spec.label,
              style: TextStyle(color: spec.fg, fontWeight: FontWeight.w600)),
          if (actionable) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: spec.fg),
          ],
        ],
      ),
    );

    return Semantics(
      liveRegion: true,
      button: actionable,
      label: 'Connection: ${spec.label}'
          '${spec.actionHint != null ? '. ${spec.actionHint}' : ''}',
      child: actionable
          ? InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => onTap!(connection),
              child: pill,
            )
          : pill,
    );
  }

  _BadgeSpec _describe(BuildContext context, PixyConnectionState s) {
    final cs = Theme.of(context).colorScheme;
    _BadgeSpec spec(Color fg, IconData icon, String label,
            {bool busy = false, String? actionHint}) =>
        _BadgeSpec(
          fg: fg,
          bg: fg.withValues(alpha: 0.15),
          icon: icon,
          label: label,
          busy: busy,
          actionHint: actionHint,
        );

    switch (s) {
      case PixyConnectionState.connecting:
        return spec(cs.primary, Icons.sync, 'Searching…', busy: true);
      case PixyConnectionState.connected:
        return spec(cs.primary, Icons.videocam, 'Connected');
      case PixyConnectionState.cameraInUse:
        // Positive: control is fully available; another app just owns video.
        return spec(cs.tertiary, Icons.check_circle, 'Controls ready');
      case PixyConnectionState.needsPermission:
        return spec(cs.error, Icons.lock, 'Needs permission',
            actionHint: 'Open System to fix');
      case PixyConnectionState.notFound:
        return spec(cs.error, Icons.usb_off, 'No PIXY found',
            actionHint: 'Tap to retry');
      case PixyConnectionState.disconnected:
        return spec(cs.outline, Icons.videocam_off, 'Disconnected');
    }
  }
}

class _BadgeSpec {
  const _BadgeSpec({
    required this.fg,
    required this.bg,
    required this.icon,
    required this.label,
    required this.busy,
    required this.actionHint,
  });
  final Color fg;
  final Color bg;
  final IconData icon;
  final String label;
  final bool busy;
  final String? actionHint;
}
