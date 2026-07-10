import 'package:geolocator/geolocator.dart' as geo;

/// État d'une session d'enregistrement.
enum RecordingStatus { idle, recording, paused }

/// Réglages de l'enregistrement GPS.
///
/// [distanceFilterMeters] est le principal levier batterie : geolocator
/// ne délivre une nouvelle position que si l'appareil s'est déplacé d'au
/// moins cette distance depuis la précédente, plutôt qu'à intervalle de
/// temps fixe — évite de consommer du GPS/CPU pour rien à l'arrêt (pause
/// contemplative devant un panorama, bivouac...).
class RecordingConfig {
  const RecordingConfig({
    this.distanceFilterMeters = 5,
    this.accuracy = geo.LocationAccuracy.high,
    this.pointsPerBatch = 50,
    this.notificationTitle = 'Enregistrement en cours',
    this.notificationText = "Votre randonnée est en cours d'enregistrement",
  });

  /// Distance minimale (m) entre deux positions consécutives délivrées
  /// par geolocator. `LocationAccuracy.high` (plutôt que `best`/
  /// `bestForNavigation`) est déjà un compromis batterie raisonnable pour
  /// de la randonnée, qui n'a pas besoin d'une précision de guidage
  /// automobile.
  final int distanceFilterMeters;
  final geo.LocationAccuracy accuracy;

  /// Nombre de points accumulés en mémoire avant écriture d'un nouveau
  /// `RecordingPointBatch` dans Isar. Un compromis : trop bas multiplie
  /// les écritures disque (donc l'usure/la latence) ; trop haut augmente
  /// la quantité de données perdues en cas d'arrêt brutal du processus
  /// entre deux flushs.
  final int pointsPerBatch;

  /// Titre/texte de la notification Android persistante du foreground
  /// service (voir `RecordingService._buildLocationSettings`).
  final String notificationTitle;
  final String notificationText;
}
