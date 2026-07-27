import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../gpx/gpx_models.dart';
import '../../models/trace.dart';
import '../../utils/geo_utils.dart';
import '../../utils/settings_service.dart';

/// Profil altimétrique d'une trace : distance cumulée en abscisse, altitude
/// en ordonnée. Les altitudes proviennent des points déjà enregistrés le
/// long de la trace (GPX importé ou enregistrement GPS) -- aucune requête
/// réseau, cohérent avec le fonctionnement "100% déconnecté" du reste de
/// l'app. Les éventuels trous (altitude non fournie par le capteil/le
/// fichier pour certains points) sont comblés par interpolation linéaire
/// entre les points connus.
class ElevationProfileDialog extends StatefulWidget {
  final Trace trace;
  final List<GpxTrackPoint> points;

  const ElevationProfileDialog({
    super.key,
    required this.trace,
    required this.points,
  });

  @override
  State<ElevationProfileDialog> createState() => _ElevationProfileDialogState();
}

class _ElevationProfileDialogState extends State<ElevationProfileDialog> {
  static const _maxZoom = 20.0;

  late List<double> _distancesM;
  late List<double> _elevations;
  late double _totalDistanceM;
  late double _minEle;
  late double _maxEle;

  double _scale = 1.0;
  double _panM = 0.0;
  double _baseScale = 1.0;
  int? _tapIndex;
  double _chartWidth = 1;

  @override
  void initState() {
    super.initState();
    _buildSeries();
  }

  void _buildSeries() {
    final pts = widget.points;
    final dist = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      dist[i] = dist[i - 1] +
          GeoUtils.haversineMeters(pts[i - 1].latitude, pts[i - 1].longitude,
              pts[i].latitude, pts[i].longitude);
    }
    _distancesM = dist;
    _totalDistanceM = dist.isEmpty ? 0 : dist.last;

    // Interpolation linéaire des altitudes manquantes entre deux points
    // connus, puis prolongement de la première/dernière valeur connue vers
    // les extrémités s'il en manque aussi là.
    final ele = List<double?>.from(pts.map((p) => p.elevation));
    int? lastKnown;
    for (var i = 0; i < ele.length; i++) {
      if (ele[i] == null) continue;
      if (lastKnown != null && i - lastKnown > 1) {
        final v0 = ele[lastKnown]!;
        final v1 = ele[i]!;
        final span = dist[i] - dist[lastKnown];
        for (var j = lastKnown + 1; j < i; j++) {
          final t = span == 0 ? 0.0 : (dist[j] - dist[lastKnown]) / span;
          ele[j] = v0 + (v1 - v0) * t;
        }
      }
      lastKnown = i;
    }
    final firstKnown = ele.indexWhere((e) => e != null);
    final lastKnownIdx = ele.lastIndexWhere((e) => e != null);
    if (firstKnown != -1) {
      for (var i = 0; i < firstKnown; i++) {
        ele[i] = ele[firstKnown];
      }
      for (var i = lastKnownIdx + 1; i < ele.length; i++) {
        ele[i] = ele[lastKnownIdx];
      }
    }
    _elevations = ele.map((e) => e ?? 0.0).toList();

    if (_elevations.isNotEmpty) {
      _minEle = _elevations.reduce(min);
      _maxEle = _elevations.reduce(max);
    } else {
      _minEle = 0;
      _maxEle = 0;
    }
  }

  double get _visibleWidthM => _totalDistanceM / _scale;

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_totalDistanceM <= 0 || _chartWidth <= 0) return;
    setState(() {
      final oldVisibleWidthM = _visibleWidthM;
      final newScale = (_baseScale * details.scale).clamp(1.0, _maxZoom);
      final newVisibleWidthM = _totalDistanceM / newScale;

      // Ancre le point sous le doigt/le centre du pincement pour que le
      // zoom "grossisse" ce point plutôt que de recentrer la fenêtre.
      final focalFraction =
          (details.localFocalPoint.dx / _chartWidth).clamp(0.0, 1.0);
      final focalM = _panM + focalFraction * oldVisibleWidthM;
      _panM = focalM - focalFraction * newVisibleWidthM;
      _scale = newScale;

      // Déplacement (un doigt ou pincement décentré) en mètres, converti à
      // partir du déplacement en pixels à l'échelle courante.
      final pixelsPerMeter = _chartWidth / newVisibleWidthM;
      _panM -= details.focalPointDelta.dx / pixelsPerMeter;

      _panM = _panM.clamp(0.0, max(0.0, _totalDistanceM - newVisibleWidthM));
    });
  }

  void _resetZoom() {
    setState(() {
      _scale = 1.0;
      _panM = 0.0;
      _tapIndex = null;
    });
  }

  void _onTapUp(TapUpDetails details) {
    if (_distancesM.isEmpty || _chartWidth <= 0) return;
    final targetM =
        _panM + (details.localPosition.dx / _chartWidth) * _visibleWidthM;
    var closest = 0;
    var closestDelta = double.infinity;
    for (var i = 0; i < _distancesM.length; i++) {
      final delta = (_distancesM[i] - targetM).abs();
      if (delta < closestDelta) {
        closestDelta = delta;
        closest = i;
      }
    }
    setState(() => _tapIndex = _tapIndex == closest ? null : closest);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final noData = widget.points.every((p) => p.elevation == null);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 60),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            if (noData)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Aucune donnée d\'altitude disponible pour cette trace.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: _buildSummaryRow(settings),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  height: 240,
                  child: LayoutBuilder(builder: (context, constraints) {
                    _chartWidth = constraints.maxWidth;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onTapUp: _onTapUp,
                      child: CustomPaint(
                        size: Size(constraints.maxWidth, constraints.maxHeight),
                        painter: _ElevationChartPainter(
                          distancesM: _distancesM,
                          elevations: _elevations,
                          minEle: _minEle,
                          maxEle: _maxEle,
                          windowStartM: _panM,
                          windowWidthM: _visibleWidthM,
                          highlightIndex: _tapIndex,
                          unitSystem: settings.unitSystem,
                          lineColor: Colors.greenAccent,
                          fillColor: Colors.greenAccent.withValues(alpha: 0.15),
                          gridColor: Colors.white12,
                          textColor: Colors.white38,
                        ),
                      ),
                    );
                  }),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Pincez pour zoomer, glissez pour naviguer',
                          style: TextStyle(color: Colors.white38, fontSize: 11)),
                    ),
                    if (_scale > 1.0)
                      TextButton(
                        onPressed: _resetZoom,
                        child: const Text('RÉINITIALISER',
                            style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.blueAccent.withValues(alpha: 0.8), Colors.blue.withValues(alpha: 0.8)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.show_chart, color: Colors.black87, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Profil altimétrique — ${widget.trace.name}',
                style: const TextStyle(
                    color: Colors.black87, fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.black87),
            onPressed: () => Navigator.pop(context),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(SettingsService settings) {
    final dist = settings.unitSystem == UnitSystem.metric
        ? '${(_totalDistanceM / 1000).toStringAsFixed(1)} km'
        : '${(_totalDistanceM * 0.000621371).toStringAsFixed(1)} mi';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _stat('Distance', dist),
        _stat('Dénivelé +', '${widget.trace.totalElevationGainMeters.round()} m'),
        _stat('Dénivelé -', '${widget.trace.totalElevationLossMeters.round()} m'),
        _stat('Altitude max', '${_maxEle.round()} m'),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    );
  }
}

class _ElevationChartPainter extends CustomPainter {
  _ElevationChartPainter({
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
  bool shouldRepaint(covariant _ElevationChartPainter oldDelegate) =>
      oldDelegate.windowStartM != windowStartM ||
      oldDelegate.windowWidthM != windowWidthM ||
      oldDelegate.highlightIndex != highlightIndex;
}
