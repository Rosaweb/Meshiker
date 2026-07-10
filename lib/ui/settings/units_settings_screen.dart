import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/settings_service.dart';

class UnitsSettingsScreen extends StatelessWidget {
  const UnitsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unités de mesure'),
      ),
      body: Consumer<SettingsService>(
        builder: (context, settings, child) {
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Système de mesure', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
              ),
              RadioListTile<UnitSystem>(
                title: const Text('Métrique (m, km, km/h)'),
                value: UnitSystem.metric,
                groupValue: settings.unitSystem,
                onChanged: (val) => val != null ? settings.setUnitSystem(val) : null,
              ),
              RadioListTile<UnitSystem>(
                title: const Text('Impérial (ft, mi, mph)'),
                value: UnitSystem.imperial,
                groupValue: settings.unitSystem,
                onChanged: (val) => val != null ? settings.setUnitSystem(val) : null,
              ),
              const Divider(),
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Température', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
              ),
              SwitchListTile(
                title: const Text('Utiliser Celsius'),
                subtitle: Text(settings.useCelsius ? 'Celsius (°C)' : 'Fahrenheit (°F)'),
                value: settings.useCelsius,
                onChanged: (val) => settings.setTemperatureUnit(val),
              ),
            ],
          );
        },
      ),
    );
  }
}
