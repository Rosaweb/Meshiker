import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

import '../database/isar_service.dart';
import '../recording/recording_service.dart';
import '../utils/settings_service.dart';
import '../utils/subscription_service.dart';
import '../weather/trace_weather_sampler.dart';
import '../weather/weather_api_client.dart';
import '../weather/weather_conditions.dart';
import '../weather/weather_models.dart';
import '../weather/weather_service.dart';

/// Page Météo plein écran (§3 de `spec-meteo.md`). Point d'entrée unique
/// pour les deux tiers : ouverte par double-tap sur la stat card « Météo »
/// du volet Navigation.
///
/// - Bandeau supérieur (§3.3) : rappelle que la météo est celle de la
///   position actuelle, avec un appel vers le paywall pour les prévisions
///   le long d'une trace.
/// - « Aujourd'hui » (§3.4) : heures restantes jusqu'à minuit local. Gratuit
///   (ou premium sans trace chargée) = 1 point, position actuelle. Premium
///   avec trace chargée = 1 point par heure restante, échantillonné le long
///   de la trace, avec kilométrage.
/// - « 4 jours suivants » (§3.5) : un appel `forecast.days` (days=5), jour 0
///   ignoré. Clic sur une ligne → détail jour/nuit déjà présent dans la
///   réponse, sans nouvel appel.
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  late Future<_WeatherPageData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _refresh() {
    context.read<WeatherService>().client.clearCache();
    setState(() => _future = _load());
  }

  Future<_WeatherPageData> _load() async {
    final client = context.read<WeatherService>().client;
    final settings = context.read<SettingsService>();
    final recording = context.read<RecordingService>();
    final isar = context.read<IsarService>();
    final isPremium = context.read<SubscriptionService>().isPremium;
    final units = settings.weatherUnitSystem;

    final pos = recording.currentPosition.value;
    if (pos == null) {
      throw const WeatherUnavailable(WeatherUnavailableReason.offline,
          detail: 'Position GPS indisponible.');
    }

    final now = DateTime.now();
    final remainingHours = hoursUntilLocalMidnight(now);

    final trace = recording.activeRoadmapTrace;
    final useTrace = isPremium && trace != null;

    // --- Section "Aujourd'hui" ---
    List<HourForecast> today;
    if (useTrace) {
      final polyline = await isar.getTracePolyline(trace);
      final speedKmh = effectiveSpeedKmh(
        currentOutingKmh: recording.averageSpeedDailyMps.value * 3.6,
        globalHistoryKmh: recording.averageSpeedGlobalMps.value * 3.6,
      );
      final samples = sampleAlongTrace(
        polyline: polyline,
        startOffsetMeters: recording.trackDistanceDoneMeters.value,
        spacingMeters: speedKmh * 1000, // vitesse (km/h) x 1 h
        count: remainingHours,
      );
      today = await _loadTraceHours(client, samples, remainingHours, units);
    } else {
      today = await client.forecastHours(
        lat: pos.latitude,
        lon: pos.longitude,
        hours: remainingHours,
        units: units,
      );
    }

    // --- Section "4 jours suivants" (échec non bloquant) ---
    List<DayForecast> nextDays = const [];
    String? daysError;
    try {
      final days = await client.forecastDays(
        lat: pos.latitude,
        lon: pos.longitude,
        days: 5,
        units: units,
      );
      // Jour 0 = aujourd'hui, déjà couvert par la section "Aujourd'hui".
      nextDays = days.length > 1 ? days.sublist(1) : const [];
    } on WeatherUnavailable catch (e) {
      daysError = e.frenchMessage;
    }

    return _WeatherPageData(
      today: today,
      alongTrace: useTrace,
      traceName: useTrace ? trace.name : null,
      premium: isPremium,
      nextDays: nextDays,
      daysError: daysError,
    );
  }

  /// Premium + trace : un appel `forecast.hours` par point échantillonné.
  /// Pour le point d'indice `i` (position atteinte après `i` heures), on lit
  /// l'enregistrement de la `i`-ème heure de sa réponse.
  Future<List<HourForecast>> _loadTraceHours(
    WeatherApiClient client,
    List<TraceSamplePoint> samples,
    int remainingHours,
    UnitSystem units,
  ) async {
    final rows = <HourForecast>[];
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final response = await client.forecastHours(
        lat: s.lat,
        lon: s.lon,
        hours: remainingHours,
        units: units,
      );
      if (response.isEmpty) continue;
      final pick = response[i < response.length ? i : response.length - 1];
      rows.add(pick.copyWith(distanceAlongTraceMeters: s.distanceAlongTraceMeters));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsService>().accentColor;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Météo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<_WeatherPageData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(child: CircularProgressIndicator(color: accent));
          }
          if (snapshot.hasError) {
            return _ErrorView(
              message: _messageFor(snapshot.error),
              onRetry: _refresh,
            );
          }
          return _WeatherPageBody(data: snapshot.data!, accent: accent);
        },
      ),
    );
  }

  String _messageFor(Object? error) {
    if (error is WeatherUnavailable) return error.frenchMessage;
    return 'Météo indisponible.';
  }
}

class _WeatherPageData {
  final List<HourForecast> today;
  final bool alongTrace;
  final String? traceName;
  final bool premium;
  final List<DayForecast> nextDays;
  final String? daysError;

  _WeatherPageData({
    required this.today,
    required this.alongTrace,
    required this.traceName,
    required this.premium,
    required this.nextDays,
    required this.daysError,
  });
}

class _WeatherPageBody extends StatelessWidget {
  final _WeatherPageData data;
  final Color accent;
  const _WeatherPageBody({required this.data, required this.accent});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _TopBanner(data: data, accent: accent),
        const SizedBox(height: 20),
        _sectionTitle(data.alongTrace ? 'AUJOURD\'HUI — LE LONG DE LA TRACE' : 'AUJOURD\'HUI'),
        if (data.alongTrace && data.traceName != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(data.traceName!,
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        const SizedBox(height: 10),
        if (data.today.isEmpty)
          const _Note('Aucune donnée horaire pour aujourd\'hui.')
        else
          ...data.today.map((h) => _HourTile(hour: h, showKm: data.alongTrace, accent: accent)),
        if (data.premium && !data.alongTrace)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: _Note(
                'Chargez une trace (« Naviguer ») pour des prévisions le long du parcours.'),
          ),
        const SizedBox(height: 28),
        _sectionTitle('4 JOURS SUIVANTS'),
        const SizedBox(height: 10),
        if (data.daysError != null)
          _Note(data.daysError!)
        else if (data.nextDays.isEmpty)
          const _Note('Prévisions journalières indisponibles.')
        else
          ...data.nextDays.take(4).map((d) => _DayTile(day: d, accent: accent)),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(text,
      style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.bold));
}

class _TopBanner extends StatelessWidget {
  final _WeatherPageData data;
  final Color accent;
  const _TopBanner({required this.data, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.my_location, color: accent, size: 16),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Météo de votre position actuelle',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ),
            ],
          ),
          if (!data.premium) ...[
            const SizedBox(height: 10),
            const Text(
              'Passez à Premium pour des prévisions personnalisées heure par '
              'heure le long d\'une trace chargée.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton(
                onPressed: () => RevenueCatUI.presentPaywall(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.black,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Voir Premium'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HourTile extends StatelessWidget {
  final HourForecast hour;
  final bool showKm;
  final Color accent;
  const _HourTile({required this.hour, required this.showKm, required this.accent});

  @override
  Widget build(BuildContext context) {
    final time = hour.time;
    final hLabel = time == null
        ? '--'
        : '${time.hour.toString().padLeft(2, '0')}h';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hLabel,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                if (showKm && hour.distanceAlongTraceMeters != null)
                  Text(_km(hour.distanceAlongTraceMeters!),
                      style: TextStyle(color: accent, fontSize: 10)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(weatherConditionIcon(hour.conditionType), color: accent, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _WeatherFmt.temp(hour.temperature, hour.temperatureUnit) +
                      (hour.feelsLike != null
                          ? '  (ressenti ${_WeatherFmt.temp(hour.feelsLike, hour.temperatureUnit)})'
                          : ''),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (hour.rainProbabilityPercent != null)
                      '${hour.rainProbabilityPercent}% pluie',
                    if ((hour.qpfQuantity ?? 0) > 0)
                      _WeatherFmt.precip(hour.qpfQuantity, hour.qpfUnit),
                    if (hour.windSpeed != null)
                      _WeatherFmt.wind(hour.windSpeed, hour.windUnit),
                    if (hour.pressureMb != null)
                      _WeatherFmt.pressure(hour.pressureMb),
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _km(double meters) => meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} km'
      : '${meters.round()} m';
}

class _DayTile extends StatefulWidget {
  final DayForecast day;
  final Color accent;
  const _DayTile({required this.day, required this.accent});

  @override
  State<_DayTile> createState() => _DayTileState();
}

class _DayTileState extends State<_DayTile> {
  bool _expanded = false;

  static const _weekdays = [
    'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'
  ];
  static const _months = [
    'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'
  ];

  String get _label {
    final d = widget.day.date;
    if (d == null) return 'Jour';
    return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final accent = widget.accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(weatherConditionIcon(day.conditionType), color: accent, size: 30),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_label,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(weatherConditionLabelFr(day.conditionType),
                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (day.tempMax != null && day.tempMin != null)
                        Text(
                          '${_WeatherFmt.temp(day.tempMax, day.temperatureUnit)} / ${_WeatherFmt.temp(day.tempMin, day.temperatureUnit)}',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      if (day.rainProbabilityPercent != null)
                        Text('${day.rainProbabilityPercent}% pluie',
                            style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white38),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                children: [
                  const Divider(color: Colors.white12),
                  _HalfDayRow(
                      icon: Icons.wb_sunny_outlined,
                      label: 'Jour (7h–19h)',
                      half: day.daytime,
                      accent: accent),
                  const SizedBox(height: 8),
                  _HalfDayRow(
                      icon: Icons.nightlight_outlined,
                      label: 'Nuit (19h–7h)',
                      half: day.nighttime,
                      accent: accent),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HalfDayRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final HalfDayForecast half;
  final Color accent;
  const _HalfDayRow(
      {required this.icon,
      required this.label,
      required this.half,
      required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.white38, size: 18),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(weatherConditionIcon(half.conditionType), color: accent, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(weatherConditionLabelFr(half.conditionType),
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (half.rainProbabilityPercent != null)
                    '${half.rainProbabilityPercent}% pluie',
                  if ((half.qpfQuantity ?? 0) > 0)
                    _WeatherFmt.precip(half.qpfQuantity, half.qpfUnit),
                  if (half.windSpeed != null)
                    _WeatherFmt.wind(half.windSpeed, half.windUnit),
                ].join(' · '),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Colors.white38, fontSize: 12));
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38)),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}

/// Formatage des valeurs météo. Aucune conversion : l'unité vient déjà de la
/// réponse API (§5). La pression reste toujours en hPa.
class _WeatherFmt {
  static String temp(double? degrees, String? unit) {
    if (degrees == null) return '—';
    final u = (unit ?? '').toUpperCase();
    final symbol = u.startsWith('F') ? '°F' : '°C';
    return '${degrees.round()}$symbol';
  }

  static String wind(double? value, String? unit) {
    if (value == null) return '';
    final u = (unit ?? '').toUpperCase();
    final symbol = u.contains('MILE') ? 'mph' : 'km/h';
    return '${value.round()} $symbol vent';
  }

  static String precip(double? quantity, String? unit) {
    if (quantity == null) return '';
    final u = (unit ?? '').toUpperCase();
    if (u.contains('INCH')) return '${quantity.toStringAsFixed(2)} in';
    return '${quantity.toStringAsFixed(1)} mm';
  }

  static String pressure(double? mb) =>
      mb == null ? '' : '${mb.round()} hPa';
}
