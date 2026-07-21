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
  
  String? localPath; // Path to the .mbtiles file once downloaded
  int sizeBytes = 0;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}
