import 'package:flutter/material.dart';
import 'package:open_meteo/open_meteo.dart';
import 'package:provider/provider.dart';

import '../recording/recording_service.dart';
import '../utils/weather_service.dart';

/// Écran météo plein écran, volontairement minimal (prévisions du jour et
/// du lendemain seulement) -- à peaufiner plus tard une fois le design
/// définitif choisi.
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  @override
  void initState() {
    super.initState();
    final weather = context.read<WeatherService>();
    if (weather.segment == null) {
      final pos = context.read<RecordingService>().currentPosition.value;
      weather.refresh(pos?.latitude, pos?.longitude);
    }
  }

  @override
  Widget build(BuildContext context) {
    final weather = context.watch<WeatherService>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Météo'),
      ),
      body: _buildBody(weather),
    );
  }

  Widget _buildBody(WeatherService weather) {
    if (weather.isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.greenAccent));
    }
    if (weather.error != null) {
      return Center(
        child: Text(weather.error!,
            style: const TextStyle(color: Colors.white38)),
      );
    }
    final segment = weather.segment;
    if (segment == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text('Activez la météo depuis le tableau de bord.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38)),
        ),
      );
    }

    final codes = _sortedEntries(segment, WeatherDaily.weather_code);
    final maxes = _sortedEntries(segment, WeatherDaily.temperature_2m_max);
    final mins = _sortedEntries(segment, WeatherDaily.temperature_2m_min);
    final precip =
        _sortedEntries(segment, WeatherDaily.precipitation_probability_max);
    const dayLabels = ['Aujourd\'hui', 'Demain'];

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: dayLabels.length,
      itemBuilder: (context, i) {
        if (i >= codes.length) return const SizedBox.shrink();
        final code = codes[i].value.toInt();
        final max = i < maxes.length ? maxes[i].value.round() : null;
        final min = i < mins.length ? mins[i].value.round() : null;
        final rainChance = i < precip.length ? precip[i].value.round() : null;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(weatherCodeIcon(code), color: Colors.greenAccent, size: 36),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dayLabels[i],
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(weatherCodeLabel(code),
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (max != null && min != null)
                    Text('$max° / $min°',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                  if (rainChance != null)
                    Text('$rainChance% pluie',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  List<MapEntry<DateTime, num>> _sortedEntries(
      ResponseSegment segment, WeatherDaily param) {
    final entries = segment.dailyData[param]?.values.entries.toList() ?? [];
    entries.sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }
}
