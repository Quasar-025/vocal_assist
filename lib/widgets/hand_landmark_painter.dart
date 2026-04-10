import 'package:flutter/material.dart';
import 'package:gesture_voice_app/services/camera_gesture_service.dart';

class HandLandmarkPainter extends CustomPainter {
  HandLandmarkPainter({
    required this.points,
    required this.connections,
    required this.mirrorX,
  });

  final List<Offset> points;
  final List<LandmarkConnection> connections;
  final bool mirrorX;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint linePaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final Paint pointPaint = Paint()
      ..color = const Color(0xFFFF6D00)
      ..style = PaintingStyle.fill;

    final Paint ringPaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    Offset mapPoint(Offset normalized) {
      final double nx = mirrorX ? (1.0 - normalized.dx) : normalized.dx;
      return Offset(nx * size.width, normalized.dy * size.height);
    }

    for (final LandmarkConnection connection in connections) {
      final Offset start = mapPoint(connection.start);
      final Offset end = mapPoint(connection.end);
      canvas.drawLine(start, end, linePaint);
    }

    for (final Offset point in points) {
      final Offset p = mapPoint(point);
      canvas.drawCircle(p, 5, pointPaint);
      canvas.drawCircle(p, 7, ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant HandLandmarkPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.connections != connections ||
        oldDelegate.mirrorX != mirrorX;
  }
}
