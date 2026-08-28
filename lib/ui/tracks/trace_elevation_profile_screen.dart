import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../gpx/gpx_models.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/trace.dart';
import '../../utils/settings_service.dart';
import 'elevation_chart_painter.dart';
import 'elevation_profile_data.dart';

/// Profil altimétrique en plein écran, forcé en mode paysage : ouvert
/// depuis l'aperçu embarqué dans TrackEditScreen. Reprend le graphe
/// pincer-zoomer/glisser/toucher déjà écrit (cf. ElevationChartPainter et
/// ElevationSeries), juste sorti de son ancien format popup.
class TraceElevationProfileScreen extends StatefulWidget {
  final Trace trace;
  final List<GpxTrackPoint> points;

  const TraceElevationProfileScreen({
    super.key,
    required this.trace,
    required this.points,
  });

  @override
  State<TraceElevationProfileScreen> createState() =>
      _TraceElevationProfileScreenState();
}

class _TraceElevationProfileScreenState
    extends State<TraceElevationProfileScreen> {
  static const _maxZoom = 20.0;

  late final ElevationSeries _series;
  bool _orientationRestored = false;

  double _scale = 1.0;
  double _panM = 0.0;
  double _baseScale = 1.0;
  int? _tapIndex;
  double _chartWidth = 1;

  @override
  void initState() {
    super.initState();
    _series = ElevationSeries.fromPoints(widget.points);
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  @override
  void dispose() {
    _restoreOrientation();
    super.dispose();
  }

  /// Idempotent : appelé à la fois par le bouton "Retour" explicite (avant
  /// le pop) et par dispose()/onPopInvokedWithResult (geste système), pour
  /// que l'orientation soit restaurée au plus tôt quel que soit le chemin
  /// de sortie.
  void _restoreOrientation() {
    if (_orientationRestored) return;
    _orientationRestored = true;
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  void _handleBack() {
    _restoreOrientation();
    Navigator.of(context).pop();
  }

  double get _visibleWidthM => _series.totalDistanceM / _scale;

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_series.totalDistanceM <= 0 || _chartWidth <= 0) return;
    setState(() {
      final oldVisibleWidthM = _visibleWidthM;
      final newScale = (_baseScale * details.scale).clamp(1.0, _maxZoom);
      final newVisibleWidthM = _series.totalDistanceM / newScale;

      final focalFraction =
          (details.localFocalPoint.dx / _chartWidth).clamp(0.0, 1.0);
      final focalM = _panM + focalFraction * oldVisibleWidthM;
      _panM = focalM - focalFraction * newVisibleWidthM;
      _scale = newScale;

      final pixelsPerMeter = _chartWidth / newVisibleWidthM;
      _panM -= details.focalPointDelta.dx / pixelsPerMeter;

      _panM = _panM.clamp(0.0, max(0.0, _series.totalDistanceM - newVisibleWidthM));
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
    if (_series.distancesM.isEmpty || _chartWidth <= 0) return;
    final targetM =
        _panM + (details.localPosition.dx / _chartWidth) * _visibleWidthM;
    var closest = 0;
    var closestDelta = double.infinity;
    for (var i = 0; i < _series.distancesM.length; i++) {
      final delta = (_series.distancesM[i] - targetM).abs();
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
    final loc = AppLocalizations.of(context)!;
    final noData = widget.points.every((p) => p.elevation == null);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _restoreOrientation();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              if (noData)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        loc.noElevationDataForTraceMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38),
                      ),
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: _buildSummaryRow(settings, loc),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: LayoutBuilder(builder: (context, constraints) {
                      _chartWidth = constraints.maxWidth;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        onTapUp: _onTapUp,
                        child: CustomPaint(
                          size: Size(constraints.maxWidth, constraints.maxHeight),
                          painter: ElevationChartPainter(
                            distancesM: _series.distancesM,
                            elevations: _series.elevations,
                            minEle: _series.minEle,
                            maxEle: _series.maxEle,
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
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(loc.pinchZoomDragHintMessage,
                            style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      ),
                      if (_scale > 1.0)
                        TextButton(
                          onPressed: _resetZoom,
                          child: Text(loc.resetButtonUppercase,
                              style: const TextStyle(color: Colors.greenAccent, fontSize: 11)),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final loc = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.blueAccent.withValues(alpha: 0.8), Colors.blue.withValues(alpha: 0.8)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black87),
            onPressed: _handleBack,
            visualDensity: VisualDensity.compact,
          ),
          const Icon(Icons.show_chart, color: Colors.black87, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(loc.elevationProfileTitle(widget.trace.name),
                style: const TextStyle(
                    color: Colors.black87, fontSize: 15, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(SettingsService settings, AppLocalizations loc) {
    final dist = settings.unitSystem == UnitSystem.metric
        ? '${(_series.totalDistanceM / 1000).toStringAsFixed(1)} km'
        : '${(_series.totalDistanceM * 0.000621371).toStringAsFixed(1)} mi';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _stat(loc.distanceLabel, dist),
        _stat(loc.elevationGainLabel, '${widget.trace.totalElevationGainMeters.round()} m'),
        _stat(loc.elevationLossLabel, '${widget.trace.totalElevationLossMeters.round()} m'),
        _stat(loc.maxAltitudeLabel, '${_series.maxEle.round()} m'),
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
