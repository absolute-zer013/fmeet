import 'dart:async';

import 'package:flutter/material.dart';

/// Slider with a label, min/max/value readout and a debounced apply callback
/// (spec §6 image panel). Applies the value after the user stops dragging for
/// [debounce], plus immediately on release.
class LabeledSlider extends StatefulWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.enabled = true,
    this.disabledHint,
    this.valueFormatter,
    this.debounce = const Duration(milliseconds: 120),
    this.trailing,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool enabled;
  final String? disabledHint;
  final ValueChanged<double> onChanged;
  final String Function(double)? valueFormatter;
  final Duration debounce;
  final Widget? trailing;

  @override
  State<LabeledSlider> createState() => _LabeledSliderState();
}

class _LabeledSliderState extends State<LabeledSlider> {
  late double _value = widget.value;
  Timer? _debounce;

  @override
  void didUpdateWidget(LabeledSlider old) {
    super.didUpdateWidget(old);
    // Reflect external changes when not actively dragging.
    if (old.value != widget.value && _debounce == null) {
      _value = widget.value;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(double v) {
    setState(() => _value = v);
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      widget.onChanged(v);
      _debounce = null;
    });
  }

  void _onChangeEnd(double v) {
    _debounce?.cancel();
    _debounce = null;
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = widget.valueFormatter ?? (v) => v.round().toString();
    final clamped = _value.clamp(widget.min, widget.max);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.45,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(widget.label, style: theme.textTheme.labelLarge),
              const Spacer(),
              if (widget.trailing != null) widget.trailing!,
              Text(fmt(clamped), style: theme.textTheme.labelMedium),
            ],
          ),
          Slider(
            value: clamped,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: fmt(clamped),
            onChanged: widget.enabled ? _onChanged : null,
            onChangeEnd: widget.enabled ? _onChangeEnd : null,
          ),
          if (!widget.enabled && widget.disabledHint != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(widget.disabledHint!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}
