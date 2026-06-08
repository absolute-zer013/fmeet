/// Capture resolutions the PIXY advertises on its MJPG stream (from
/// `v4l2-ctl --list-formats-ext`). Selecting one sets the format PixyControl's
/// own mpv stream/preview requests. Digital zoom (§4.6) only takes effect at
/// 2K/1080p/720p @30 — NOT at 4K — so [zoomCapable] gates the zoom slider.
enum CaptureResolution {
  uhd4k(3840, 2160, '4K', supports60: false),
  qhd2k(2560, 1440, '2K', supports60: false),
  fhd1080(1920, 1080, '1080p', supports60: true),
  hd720(1280, 720, '720p', supports60: true);

  const CaptureResolution(this.width, this.height, this.label,
      {required this.supports60});

  final int width;
  final int height;
  final String label;

  /// Whether 60 fps is available at this size (1080p/720p only).
  final bool supports60;

  /// Stable persistence key, e.g. `1920x1080`.
  String get key => '${width}x$height';

  /// Whether digital zoom works at this resolution (everything except 4K).
  bool get zoomCapable => this != CaptureResolution.uhd4k;

  static CaptureResolution fromKey(String? key) =>
      CaptureResolution.values.firstWhere((r) => r.key == key,
          orElse: () => CaptureResolution.fhd1080);

  /// Default — 1080p balances quality, 30/60 fps support, and zoom capability.
  static const CaptureResolution defaultValue = CaptureResolution.fhd1080;
}
