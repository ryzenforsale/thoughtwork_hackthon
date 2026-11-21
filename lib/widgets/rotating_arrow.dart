import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// How the arrow should currently be presented.
enum ArrowMode { normal, northUp, veryClose, stale, waiting }

/// The compass-relative direction indicator.
///
/// It listens to [angle] directly so only this widget repaints when the
/// compass ticks, instead of rebuilding the whole tracking screen.
class ArrowDisplay extends StatefulWidget {
  /// Continuous (unwrapped) angle in degrees. Positive rotates clockwise.
  final ValueListenable<double> angle;

  /// Half-width of the uncertainty cone in degrees.
  final double uncertaintyDeg;

  final ArrowMode mode;
  final String friendName;
  final int? friendAgeSeconds;

  const ArrowDisplay({
    super.key,
    required this.angle,
    required this.uncertaintyDeg,
    required this.mode,
    required this.friendName,
    this.friendAgeSeconds,
  });

  @override
  State<ArrowDisplay> createState() => _ArrowDisplayState();
}

class _ArrowDisplayState extends State<ArrowDisplay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  bool get _showPulse =>
      widget.mode == ArrowMode.normal ||
      widget.mode == ArrowMode.northUp ||
      widget.mode == ArrowMode.veryClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      height: 250,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_showPulse) _pulseRings(),
          Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(
                widget.mode == ArrowMode.stale ? 0.10 : 0.18,
              ),
            ),
          ),
          _centerContent(),
          if (widget.mode == ArrowMode.northUp) _northBadge(),
          if (widget.mode == ArrowMode.stale) _staleBadge(),
        ],
      ),
    );
  }

  Widget _pulseRings() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final value = _pulse.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 170 + value * 55,
              height: 170 + value * 55,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.06 * (1 - value)),
              ),
            ),
            Container(
              width: 150 + value * 35,
              height: 150 + value * 35,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.10 * (1 - value)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _centerContent() {
    switch (widget.mode) {
      case ArrowMode.waiting:
        return const SizedBox(
          width: 46,
          height: 46,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        );
      case ArrowMode.veryClose:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_alt_rounded,
              size: 64,
              color: Colors.white.withOpacity(0.95),
            ),
            const SizedBox(height: 4),
            Text(
              "You're together",
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      case ArrowMode.normal:
      case ArrowMode.northUp:
      case ArrowMode.stale:
        return _arrow();
    }
  }

  Widget _arrow() {
    return AnimatedBuilder(
      animation: widget.angle,
      builder: (context, child) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: widget.angle.value),
          duration: const Duration(milliseconds: 90),
          curve: Curves.linear,
          builder: (context, angle, _) {
            return Opacity(
              opacity: widget.mode == ArrowMode.stale ? 0.35 : 1.0,
              child: Transform.rotate(
                angle: angle * math.pi / 180.0,
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (widget.uncertaintyDeg > 1)
                        CustomPaint(
                          size: const Size.square(200),
                          painter: UncertaintyWedgePainter(
                            halfWidthDeg: widget.uncertaintyDeg,
                          ),
                        ),
                      CustomPaint(
                        size: const Size.square(150),
                        painter: RealisticArrowPainter(),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _northBadge() {
    return Positioned(
      top: 2,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.28),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'N',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _staleBadge() {
    final age = widget.friendAgeSeconds;
    return Positioned(
      bottom: 2,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.32),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history, size: 12, color: Colors.white70),
            const SizedBox(width: 5),
            Text(
              age == null ? 'Last known position' : 'Last seen ${age}s ago',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft translucent wedge showing how uncertain the direction is.
class UncertaintyWedgePainter extends CustomPainter {
  final double halfWidthDeg;

  const UncertaintyWedgePainter({required this.halfWidthDeg});

  @override
  void paint(Canvas canvas, Size size) {
    if (halfWidthDeg <= 1) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.47;
    final half = halfWidthDeg.clamp(2.0, 88.0) * math.pi / 180.0;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final start = -math.pi / 2 - half;
    final sweep = 2 * half;

    final wedge = Paint()
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(0.20),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.fill;
    canvas.drawArc(rect, start, sweep, true, wedge);

    final edge = Paint()
      ..color = Colors.white.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final left =
        center + Offset(math.cos(start) * radius, math.sin(start) * radius);
    final right =
        center +
        Offset(
          math.cos(start + sweep) * radius,
          math.sin(start + sweep) * radius,
        );
    canvas.drawLine(center, left, edge);
    canvas.drawLine(center, right, edge);
  }

  @override
  bool shouldRepaint(covariant UncertaintyWedgePainter oldDelegate) =>
      (oldDelegate.halfWidthDeg - halfWidthDeg).abs() > 0.5;
}

/// Original arrow shape, kept intact.
class RealisticArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final center = Offset(size.width / 2, size.height / 2);

    final arrowLength = size.height * 0.55;
    final arrowWidth = size.width * 0.25;
    final headLength = arrowLength * 0.4;
    final tailWidth = arrowWidth * 0.35;

    final path = Path();
    path.moveTo(center.dx, center.dy - arrowLength / 2);
    path.lineTo(
      center.dx + arrowWidth / 2,
      center.dy - arrowLength / 2 + headLength,
    );
    path.lineTo(
      center.dx + tailWidth / 2,
      center.dy - arrowLength / 2 + headLength,
    );
    path.lineTo(center.dx + tailWidth / 2, center.dy + arrowLength / 2);
    path.lineTo(center.dx - tailWidth / 2, center.dy + arrowLength / 2);
    path.lineTo(
      center.dx - tailWidth / 2,
      center.dy - arrowLength / 2 + headLength,
    );
    path.lineTo(
      center.dx - arrowWidth / 2,
      center.dy - arrowLength / 2 + headLength,
    );
    path.close();

    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    canvas.drawPath(path.shift(const Offset(2, 2)), shadowPaint);
    canvas.drawPath(path, paint);
    canvas.drawPath(path, strokePaint);

    final detailPaint = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final detailPath = Path();
    detailPath.moveTo(center.dx, center.dy - arrowLength / 2 + 8);
    detailPath.lineTo(center.dx, center.dy + arrowLength / 2 - 8);
    canvas.drawPath(detailPath, detailPaint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
