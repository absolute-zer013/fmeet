import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/stream/preview_controller.dart';
import '../../state/device_controller.dart';

/// Right-side preview pane. Live video is rendered **in-app** by painting the
/// camera's MJPG frames (piped from ffmpeg) as images — no GL/media_kit (the
/// embedded GL texture path crashes on this stack), no external window.
class PreviewView extends StatelessWidget {
  const PreviewView({super.key});

  @override
  Widget build(BuildContext context) {
    // `preview` is a stable final field — read it, don't watch. Select only
    // `previewOn` so the pane doesn't rebuild on every motor/poll notification
    // (the per-frame repaint is isolated inside _LiveView's ValueListenable).
    final controller = context.read<DeviceController>();
    final preview = controller.preview;
    final previewOn = context.select<DeviceController, bool>((c) => c.previewOn);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101114),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<PreviewState>(
        stream: preview.stateStream,
        initialData: preview.state,
        builder: (context, snapshot) {
          final state = snapshot.data ?? PreviewState.idle;
          if (previewOn) {
            return _LiveView(
              preview: preview,
              onHide: () => controller.setPreview(false),
            );
          }
          return _PaneBody(
            state: state,
            error: preview.lastError,
            onShow: () => controller.setPreview(true),
            onRetry: controller.connect,
          );
        },
      ),
    );
  }
}

/// Live MJPEG view — repaints as new JPEG frames arrive on [preview.frame].
class _LiveView extends StatelessWidget {
  const _LiveView({required this.preview, required this.onHide});

  final PreviewController preview;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<Uint8List?>(
          valueListenable: preview.frame,
          builder: (context, bytes, _) {
            if (bytes == null) {
              return const Center(
                child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            return Image.memory(
              bytes,
              gaplessPlayback: true, // keep the last frame while decoding next
              fit: BoxFit.contain,
              filterQuality: FilterQuality.low,
            );
          },
        ),
        Positioned(
          top: 8,
          right: 8,
          child: FilledButton.tonalIcon(
            onPressed: onHide,
            icon: const Icon(Icons.visibility_off, size: 18),
            label: const Text('Hide'),
          ),
        ),
      ],
    );
  }
}

class _PaneBody extends StatelessWidget {
  const _PaneBody({
    required this.state,
    required this.onShow,
    required this.onRetry,
    this.error,
  });

  final PreviewState state;
  final VoidCallback onShow;
  final VoidCallback onRetry;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle) = switch (state) {
      PreviewState.idle => (
          Icons.videocam_off,
          'No camera',
          'Connect a PIXY to start.',
        ),
      PreviewState.opening => (Icons.hourglass_top, 'Starting stream…', null),
      PreviewState.streaming => (
          Icons.check_circle,
          'Camera streaming',
          'Controls are active. Show the live preview below.',
        ),
      PreviewState.busy => (
          Icons.check_circle,
          'Live in another app',
          'Camera controls are ready. The video stream is held by another app '
              '(Zoom/OBS/…), so the in-app preview is unavailable.',
        ),
      PreviewState.noDevice => (
          Icons.usb_off,
          'Camera not found',
          'Check the connection and permissions.',
        ),
      PreviewState.error => (Icons.error_outline, 'Stream error', error),
    };

    final canShow = state == PreviewState.streaming;
    final canRetry =
        state == PreviewState.noDevice || state == PreviewState.error;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
            ],
            if (state == PreviewState.opening) ...[
              const SizedBox(height: 16),
              const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ],
            if (canShow) ...[
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: onShow,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Show preview'),
              ),
            ],
            if (canRetry) ...[
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
