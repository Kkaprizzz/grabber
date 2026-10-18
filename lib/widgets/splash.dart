import 'package:flutter/material.dart';

import '../theme.dart';

/// What the app shows while it loads the queue and history: the same
/// grabber on a peach disc as Android's launch screen (launch_icon.xml),
/// at the same size and spot, so the hand-off doesn't jump.
class Splash extends StatelessWidget {
  const Splash({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SizedBox.expand(
        child: Stack(
          alignment: Alignment.center,
          children: [
            const SizedBox.square(dimension: 96, child: CustomPaint(painter: _GrabberPainter())),
            Align(
              alignment: const Alignment(0, 0.32),
              child: SizedBox(
                width: 120,
                child: Semantics(label: 'Загрузка', child: const LinearProgressIndicator()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// launch_icon.xml redrawn: a 108-unit canvas scaled to the widget.
class _GrabberPainter extends CustomPainter {
  const _GrabberPainter();

  static const _disc = Color(0xFFF4B993); // ic_launcher_background
  static const _ink = Color(0xFF2E2823);
  static const _ball = Color(0xFFF8F4EF);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 108, size.height / 108);
    canvas.drawCircle(const Offset(54, 54), 40, Paint()..color = _disc);
    final stroke = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(56, 70), 7, Paint()..color = _ball);
    canvas.drawCircle(const Offset(56, 70), 7, stroke);
    final claw = Path()
      ..moveTo(56, 28)
      ..lineTo(56, 46)
      ..moveTo(44, 46)
      ..lineTo(68, 46)
      ..moveTo(46, 46)
      ..cubicTo(38, 55, 39, 66, 47, 74)
      ..moveTo(66, 46)
      ..cubicTo(74, 55, 73, 66, 65, 74);
    canvas.drawPath(claw, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
