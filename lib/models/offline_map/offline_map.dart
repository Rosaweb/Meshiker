import 'package:isar_community/isar.dart';

part 'offline_map.g.dart';

@collection
class OfflineMap {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  late String name;
  String? description;

  double minLat = 0;
  double maxLat = 0;
  double minLon = 0;
  double maxLon = 0;

  int minZoom = 0;
  int maxZoom = 18;

  double downloadProgress = 0; // 0.0 to 1.0
  bool isDownloading = false;
  bool isError = false;

  // Identifiant du fond de carte (cf. MapSourceInfo.id dans
  // maps_settings_screen.dart) téléchargé, et son urlTemplate résolu au
  // moment du téléchargement (conservé même si la source venait à
  // disparaître de la liste). Sert à MapScreen pour ne servir les tuiles
  // locales que lorsque ce même fond de carte est affiché.
  String sourceId = 'osm_standard';
  String urlTemplate = '';

  String? localPath; // Dossier contenant les tuiles téléchargées (<id>/z/x/y.png)
  int sizeBytes = 0;

  // Nom de la Trace associée si cette carte a été créée depuis le menu
  // "Créer carte hors-ligne" d'une trace GPX (cf. TrackEditScreen) : dans
  // ce cas, taper sur la carte dans "Mes cartes > Hors ligne" doit ouvrir
  // directement le Roadmap de cette trace plutôt que ne rien faire.
  String? linkedTraceName;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}
