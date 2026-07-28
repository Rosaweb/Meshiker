import 'dart:math';

import 'package:flutter/material.dart';

import '../../utils/settings_service.dart';

class ElevationChartPainter extends CustomPainter {
  ElevationChartPainter({
    required this.distancesM,
    required this.elevations,
    required this.minEle,
    required this.maxEle,
    required this.windowStartM,
    required this.windowWidthM,
    required this.highlightIndex,
    required this.unitSystem,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
    required this.textColor,
  });

  final List<double> distancesM;
  final List<double> elevations;
  final double minEle;
  final double maxEle;
  final double windowStartM;
  final double windowWidthM;
  final int? highlightIndex;
  final UnitSystem unitSystem;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (distancesM.isEmpty || windowWidthM <= 0) return;

    final eleRange = max(maxEle - minEle, 10.0);
    final yPad = eleRange * 0.15;
    final yMin = minEle - yPad;
    final yMax = maxEle + yPad;
    final windowEndM = windowStartM + windowWidthM;

    double xFor(double d) => (d - windowStartM) / windowWidthM * size.width;
    double yFor(double e) => size.height - (e - yMin) / (yMax - yMin) * size.height;

    // Grille horizontale (altitude), recessive.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      final ele = yMax - (yMax - yMin) * i / 3;
      labelPainter.text = TextSpan(
          text: '${ele.round()} m',
          style: TextStyle(color: textColor, fontSize: 9));
      labelPainter.layout();
      labelPainter.paint(canvas, Offset(4, y + 2));
    }

    // Tracé + remplissage, limités à la fenêtre visible (+ marge pour
    // éviter un bord tronqué net).
    final path = Path();
    final fillPath = Path();
    var started = false;
    double? lastX;
    for (var i = 0; i < distancesM.length; i++) {
      final d = distancesM[i];
      if (d < windowStartM - windowWidthM * 0.02 ||
          d > windowEndM + windowWidthM * 0.02) {
        continue;
      }
      final x = xFor(d);
      final y = yFor(elevations[i]);
      if (!started) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
      lastX = x;
    }
    if (started) {
      fillPath.lineTo(lastX!, size.height);
      fillPath.close();
      canvas.drawPath(fillPath, Paint()..color = fillColor);
      canvas.drawPath(
        path,
        Paint()
          ..color = lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Repères de distance en bas (4 graduations).
    for (var i = 0; i <= 4; i++) {
      final d = windowStartM + windowWidthM * i / 4;
      final label = unitSystem == UnitSystem.metric
          ? '${(d / 1000).toStringAsFixed(1)} km'
          : '${(d * 0.000621371).toStringAsFixed(1)} mi';
      labelPainter.text = TextSpan(text: label, style: TextStyle(color: textColor, fontSize: 9));
      labelPainter.layout();
      final x = (size.width * i / 4).clamp(0.0, size.width - labelPainter.width);
      labelPainter.paint(canvas, Offset(x, size.height - 12));
    }

    // Curseur au point sélectionné (appui).
    final hi = highlightIndex;
    if (hi != null && hi < distancesM.length) {
      final d = distancesM[hi];
      if (d >= windowStartM && d <= windowEndM) {
        final x = xFor(d);
        final y = yFor(elevations[hi]);
        canvas.drawLine(Offset(x, 0), Offset(x, size.height),
            Paint()..color = textColor.withValues(alpha: 0.6));
        canvas.drawCircle(Offset(x, y), 4, Paint()..color = lineColor);
        canvas.drawCircle(
            Offset(x, y),
            4,
            Paint()
              ..color = Colors.black
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);

        final distLabel = unitSystem == UnitSystem.metric
            ? '${(d / 1000).toStringAsFixed(2)} km'
            : '${(d * 0.000621371).toStringAsFixed(2)} mi';
        final tooltip = '$distLabel · ${elevations[hi].round()} m';
        labelPainter.text = TextSpan(
            text: tooltip,
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold));
        labelPainter.layout();
        final boxWidth = labelPainter.width + 12;
        var boxX = x - boxWidth / 2;
        boxX = boxX.clamp(0.0, size.width - boxWidth);
        final boxY = (y - 28).clamp(0.0, size.height - 22);
        final rect = RRect.fromRectAndRadius(
            Rect.fromLTWH(boxX, boxY, boxWidth, 20), const Radius.circular(4));
        canvas.drawRRect(rect, Paint()..color = Colors.black87);
        labelPainter.paint(canvas, Offset(boxX + 6, boxY + 4));
      }
    }
  }

  @override
  bool shouldRepaint(covariant ElevationChartPainter oldDelegate) =>
      oldDelegate.windowStartM != windowStartM ||
      oldDelegate.windowWidthM != windowWidthM ||
      oldDelegate.highlightIndex != highlightIndex;
}
