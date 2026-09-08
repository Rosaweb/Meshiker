import 'package:flutter/material.dart';

import '../models/enums.dart';
import '../models/segment.dart';
import '../ui/settings/maps_settings_screen.dart';
import '../utils/settings_service.dart';

/// Critere utilise pour colorer un Segment a l'ecran. L'utilisateur peut
/// basculer entre ces modes (voir MapScreen) pour lire la toile
/// d'araignee sous differents angles, exactement comme demande section 3
/// du brief ("code couleur dynamique base sur la difficulte, le
/// denivele, la recence du passage ou l'indice de fiabilite
/// communautaire").
enum SegmentColorMode { difficulty, elevationGrade, recency, reliability, mode }

/// Palette et fonctions de style, regroupees ici pour que TOUT code
/// couleur de l'app passe par un seul endroit -- evite qu'un ecran
/// invente sa propre echelle de couleurs incoherente avec les autres.
class MapStyle {
  const MapStyle._();

  static const _difficultyColors = {
    DifficultyLevel.easy: Color(0xFF2E7D32),
    DifficultyLevel.moderate: Color(0xFF9E9D24),
    DifficultyLevel.difficult: Color(0xFFEF6C00),
    DifficultyLevel.veryDifficult: Color(0xFFD84315),
    DifficultyLevel.expert: Color(0xFF6A1B1A),
  };

  static const _offPathColor = Color(0xFF6D4C41);
  static const _unknownColor = Color(0xFF757575);

  static Color segmentColor(Segment segment, SegmentColorMode mode) {
    switch (mode) {
      case SegmentColorMode.mode:
        return segment.mode == SegmentMode.offPath
            ? _offPathColor
            : const Color(0xFF1565C0);

      case SegmentColorMode.difficulty:
        return _difficultyColors[segment.difficulty] ?? _unknownColor;

      case SegmentColorMode.elevationGrade:
        if (segment.distanceMeters <= 0) return _unknownColor;
        final grade = segment.elevationGainMeters / segment.distanceMeters;
        if (grade < 0.05) return _difficultyColors[DifficultyLevel.easy]!;
        if (grade < 0.10) return _difficultyColors[DifficultyLevel.moderate]!;
        if (grade < 0.15) return _difficultyColors[DifficultyLevel.difficult]!;
        if (grade < 0.25) {
          return _difficultyColors[DifficultyLevel.veryDifficult]!;
        }
        return _difficultyColors[DifficultyLevel.expert]!;

      case SegmentColorMode.recency:
        final last = segment.lastPassageAt;
        if (last == null) return _unknownColor;
        final days = DateTime.now().difference(last).inDays;
        if (days <= 7) return const Color(0xFF00C853);
        if (days <= 30) return const Color(0xFF64DD17);
        if (days <= 180) return const Color(0xFFFFD600);
        if (days <= 365) return const Color(0xFFFF6D00);
        return const Color(0xFFB71C1C);

      case SegmentColorMode.reliability:
        final r = segment.reliabilityIndex;
        if (r == null) return _unknownColor;
        return Color.lerp(const Color(0xFFB71C1C), const Color(0xFF2E7D32), r)!;
    }
  }

  static double segmentWidth(Segment segment) {
    const base = 3.0;
    final bonus =
        ((segment.reliabilityIndex ?? 0.0) * 2.0).clamp(0.0, 2.0).toDouble();
    return base + bonus;
  }

  static bool isDashed(Segment segment) => segment.mode == SegmentMode.offPath;

  static const _poiIcons = {
    POIType.summit: Icons.terrain,
    POIType.viewpoint: Icons.landscape,
    POIType.waterSource: Icons.water_drop,
    POIType.campsite: Icons.holiday_village,
    POIType.shelter: Icons.cabin,
    POIType.parking: Icons.local_parking,
    POIType.junction: Icons.call_split,
    POIType.danger: Icons.warning_amber,
    POIType.other: Icons.place,
  };

  static IconData poiIcon(POIType type) => _poiIcons[type] ?? Icons.place;

  static const _poiColors = {
    POIType.summit: Color(0xFF6A1B1A),
    POIType.viewpoint: Color(0xFF1565C0),
    POIType.waterSource: Color(0xFF0288D1),
    POIType.campsite: Color(0xFF2E7D32),
    POIType.shelter: Color(0xFF5D4037),
    POIType.parking: Color(0xFF424242),
    POIType.junction: Color(0xFF9E9D24),
    POIType.danger: Color(0xFFD32F2F),
    POIType.other: Color(0xFF757575),
  };

  static Color poiColor(POIType type) => _poiColors[type] ?? _unknownColor;

  /// Détermine quelle source de tuiles utiliser d'après les cartes favorites
  /// de l'utilisateur (ou OpenStreetMap standard s'il n'en a configuré
  /// aucune). Centralisé ici pour que MapScreen et tout autre aperçu de
  /// carte (ex: illustration d'une trace) restent cohérents entre eux.
  ///
  /// [centerLat]/[centerLon] : centre de carte courant. Si la source
  /// favorite sélectionnée a une emprise géographique (cartes nationales
  /// USGS, Kartverket…) et que ce centre tombe hors emprise, on retombe
  /// silencieusement sur la première source favorite valide ici, sinon sur
  /// OpenStreetMap — c'est le « déclenchement par zone » des cartes bonus.
  /// Sans centre fourni, aucun filtrage (comportement historique).
  static MapSourceInfo resolveTileSource(
    SettingsService settings, {
    double? centerLat,
    double? centerLon,
  }) {
    final favIds = settings.favoriteMapIds;
    if (favIds.isEmpty) {
      return availableSources.firstWhere((s) => s.id == 'osm_standard');
    }
    final currentId = favIds[settings.currentMapIndex % favIds.length];
    final picked = availableSources.firstWhere((s) => s.id == currentId,
        orElse: () => availableSources.first);

    if (centerLat == null ||
        centerLon == null ||
        picked.coversPoint(centerLat, centerLon)) {
      return picked;
    }

    for (final id in favIds) {
      final candidate = availableSources.firstWhere((s) => s.id == id,
          orElse: () => availableSources.first);
      if (candidate.coversPoint(centerLat, centerLon)) return candidate;
    }
    return availableSources.firstWhere((s) => s.id == 'osm_standard');
  }

  /// Fond de carte à utiliser pour les aperçus de traces GPX. Si
  /// l'utilisateur en a choisi un fixe (Paramètres d'affichage), on l'utilise
  /// tel quel ; sinon on retombe sur [resolveTileSource] (fond de carte
  /// actif de la carte principale), comportement historique.
  static MapSourceInfo resolveTracePreviewSource(
    SettingsService settings, {
    double? centerLat,
    double? centerLon,
  }) {
    final fixedId = settings.tracePreviewMapSourceId;
    if (fixedId == null) {
      return resolveTileSource(settings,
          centerLat: centerLat, centerLon: centerLon);
    }
    return availableSources.firstWhere((s) => s.id == fixedId,
        orElse: () => resolveTileSource(settings,
            centerLat: centerLat, centerLon: centerLon));
  }
}
