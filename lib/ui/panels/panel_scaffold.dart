import 'package:flutter/material.dart';

/// Scrollable panel body with a title — shared layout for every panel.
class PanelBody extends StatelessWidget {
  const PanelBody({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }
}

/// One-line banner shown at the top of a gated panel explaining why its
/// controls are inactive (hoisted so AI/Audio/System read the same as Control).
class GatingBanner extends StatelessWidget {
  const GatingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.surfaceContainerHighest,
      margin: const EdgeInsets.only(bottom: 16),
      child: const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('Controls inactive'),
        subtitle: Text(
            'Activate by opening the camera stream (preview) or running it in '
            'another video app.'),
      ),
    );
  }
}

/// A titled card section inside a panel.
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
