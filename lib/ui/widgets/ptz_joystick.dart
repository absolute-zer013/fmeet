import 'package:flutter/material.dart';

/// Circular drag knob → continuous velocity (spec §5.1). Drag magnitude maps to
/// velocity; release snaps back and emits a stop. Pan is +right, tilt is +up.
class PtzJoystick extends StatefulWidget {
  const PtzJoystick({
    super.key,
    required this.onDrive,
    required this.onStop,
    this.size = 200,
    this.maxVelocity = 30,
    this.enabled = true,
  });

  /// Called continuously with (panVel, tiltVel) in °/s while dragging.
  final void Function(double panVel, double tiltVel) onDrive;
  final VoidCallback onStop;
  final double size;
  final double maxVelocity;
  final bool enabled;

  @override
  State<PtzJoystick> createState() => _PtzJoystickState();
}

class _PtzJoystickState extends State<PtzJoystick> {
  Offset _knob = Offset.zero; // -1..1 in each axis

  double get _radius => widget.size / 2;
  double get _maxKnob => _radius - _knobRadius;
  static const double _knobRadius = 26;

  void _update(Offset local) {
    final center = Offset(_radius, _radius);
    var v = local - center;
    final dist = v.distance;
    if (dist > _maxKnob) v = v * (_maxKnob / dist);
    setState(() => _knob = v);
    // Normalise to -1..1, invert Y so up = +tilt.
    final nx = v.dx / _maxKnob;
    final ny = -v.dy / _maxKnob;
    widget.onDrive(nx * widget.maxVelocity, ny * widget.maxVelocity);
  }

  void _reset() {
    setState(() => _knob = Offset.zero);
    widget.onStop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final knob = _buildKnob(cs);
    return Semantics(
      label: 'Pan and tilt joystick',
      hint: widget.enabled
          ? 'Drag to move the camera, or use the arrow buttons.'
          : 'Inactive until the camera stream is live. Use the arrow buttons.',
      enabled: widget.enabled,
      child: widget.enabled
          ? knob
          : Tooltip(
              message: 'Start the camera stream to move the camera',
              child: knob,
            ),
    );
  }

  Widget _buildKnob(ColorScheme cs) {
    return Opacity(
      opacity: widget.enabled ? 1 : 0.4,
      child: GestureDetector(
        onPanStart: widget.enabled ? (d) => _update(d.localPosition) : null,
        onPanUpdate: widget.enabled ? (d) => _update(d.localPosition) : null,
        onPanEnd: widget.enabled ? (_) => _reset() : null,
        onPanCancel: widget.enabled ? _reset : null,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.surfaceContainerHighest,
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Stack(
            children: [
              // Cross-hair guides.
              Center(
                child: Icon(Icons.add, size: 28, color: cs.outline.withValues(alpha: 0.4)),
              ),
              Align(
                alignment: Alignment(
                  _maxKnob == 0 ? 0 : _knob.dx / _maxKnob,
                  _maxKnob == 0 ? 0 : _knob.dy / _maxKnob,
                ),
                child: Container(
                  width: _knobRadius * 2,
                  height: _knobRadius * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.primary,
                    boxShadow: [
                      BoxShadow(
                        color: cs.primary.withValues(alpha: 0.4),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Icon(Icons.open_with, color: cs.onPrimary, size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
