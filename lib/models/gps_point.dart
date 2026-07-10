import 'package:isar_community/isar.dart';

part 'gps_point.g.dart';

/// Un point GPS brut.
///
/// Cet objet n'a volontairement AUCUNE identité propre (pas de collection
/// Isar dédiée) : il n'existe qu'en tant qu'élément de la liste de points
/// d'un [Segment]. Le stocker en `@embedded` plutôt qu'en collection avec
/// clé étrangère évite une jointure par point — un détail qui compte
/// beaucoup quand un enregistrement de plusieurs heures en montagne
/// produit plusieurs milliers de points via le Foreground Service.
@embedded
class PointGPS {
  PointGPS();

  PointGPS.create({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.altitude,
    this.accuracyMeters,
    this.speedMps,
    this.headingDegrees,
  });

  /// Latitude en degrés décimaux (WGS84).
  double latitude = 0;

  /// Longitude en degrés décimaux (WGS84).
  double longitude = 0;

  /// Altitude en mètres si fournie par le capteur (peut être `null` en
  /// intérieur, sous couvert dense ou sur certains appareils bas de gamme).
  double? altitude;

  /// Horodatage de la mesure. Indispensable pour recalculer les vitesses,
  /// détecter les arrêts (bivouac, pause) et ordonner les points sans
  /// dépendre de l'ordre physique de la liste.
  DateTime timestamp = DateTime.now();

  /// Précision GPS rapportée par l'OS, en mètres. Permet de filtrer les
  /// points aberrants (ex : > 50 m en forêt dense ou en canyon) avant tout
  /// calcul de distance ou de découpage en segments.
  double? accuracyMeters;

  /// Vitesse instantanée en m/s, si disponible nativement (évite de la
  /// recalculer entre deux points pour l'affichage temps réel).
  double? speedMps;

  /// Cap/orientation en degrés (0-360), utile pour l'affichage de la
  /// position et de l'orientation de l'utilisateur sur la carte.
  double? headingDegrees;
}
