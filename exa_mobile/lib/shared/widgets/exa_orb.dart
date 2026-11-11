import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/exa_theme.dart';

/// Exa's presence mark: the Exa logo - the BrightForge forge ring around an
/// "E" with an orange AI spark - drawn live so it can animate.
///
/// - idle: slow breathing (scale + glow), the spark pulses
/// - thinking: the teal arc travels round the ring
///
/// Geometry matches .github/assets/exa-logo.svg (a 100-unit square).
/// Used in the chat, the floating nav button and the overlay.
class ExaOrb extends StatefulWidget {
  const ExaOrb({super.key, this.size = 36, this.thinking = false});

  final double size;
  final bool thinking;

  @override
  State<ExaOrb> createState() => _ExaOrbState();
}

class _ExaOrbState extends State<ExaOrb> with TickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.thinking) _sweep.repeat();
  }

  @override
  void didUpdateWidget(covariant ExaOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.thinking && !_sweep.isAnimating) {
      _sweep.repeat();
    } else if (!widget.thinking && _sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _breathe.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_breathe, _sweep]),
      builder: (context, _) {
        final breath = Curves.easeInOut.transform(_breathe.value);
        final scale = 0.94 + breath * 0.06;
        final glow = (widget.thinking ? 0.45 : 0.25) + breath * 0.2;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Transform.scale(
            scale: scale,
            child: CustomPaint(
              painter: _OrbPainter(
                sweep: _sweep.value,
                glow: glow,
                thinking: widget.thinking,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.sweep,
    required this.glow,
    required this.thinking,
  });

  final double sweep;
  final double glow;
  final bool thinking;

  // Logo geometry, in units of a 100 x 100 square (see exa-logo.svg).
  static const _bandR = 36.0, _bandW = 12.0;
  static const _outerR = 45.6, _outerW = 7.6;
  static const _tealW = 4.6;
  static const _barW = 6.2, _spineX = 39.5;
  static const _bars = [(39.0, 60.5), (50.0, 53.0), (61.0, 60.5)];
  static const _sparkX = 59.6, _sparkY = 50.0, _sparkR = 3.3;

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    final center = size.center(Offset.zero);
    Offset p(double x, double y) => Offset(x * k, y * k);

    // Soft teal glow behind the mark.
    canvas.drawCircle(
      center,
      size.width / 2,
      Paint()
        ..color = ExaColors.accent.withValues(alpha: glow * 0.8)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.2),
    );

    Rect ring(double r) => Rect.fromCircle(center: center, radius: r * k);
    Paint stroke(Color c, double w, [StrokeCap cap = StrokeCap.round]) =>
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * k
          ..strokeCap = cap;

    // Orange band round the bottom (4 o'clock -> 10 o'clock).
    canvas.drawArc(ring(_outerR), _rad(28), _rad(184), false,
        stroke(ExaColors.forge, _outerW, StrokeCap.butt));
    // Light band.
    canvas.drawCircle(center, _bandR * k, stroke(ExaColors.textPrimary, _bandW));
    // Teal arc set into the band; it travels round while Exa is thinking.
    final start = thinking ? 226 + sweep * 360 : 226.0;
    canvas.drawArc(ring(_bandR), _rad(start), _rad(152), false,
        stroke(ExaColors.accent, _tealW));

    // The "E".
    final ink = stroke(ExaColors.textPrimary, _barW);
    canvas.drawLine(p(_spineX, _bars.first.$1), p(_spineX, _bars.last.$1), ink);
    for (final (y, xEnd) in _bars) {
      canvas.drawLine(p(_spineX, y), p(xEnd, y), ink);
    }

    // The spark, pulsing gently with the breath.
    final pulse = 0.85 + glow * 0.5;
    canvas.drawCircle(p(_sparkX, _sparkY), _sparkR * k * pulse,
        Paint()..color = ExaColors.forge);
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.sweep != sweep || old.glow != glow || old.thinking != thinking;
}
