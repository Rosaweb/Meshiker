import 'package:isar_community/isar.dart';

import 'enums.dart';
import 'syncable.dart';

part 'utilisateur.g.dart';

/// Profil utilisateur.
///
/// En mode hors-ligne total, un utilisateur peut exister uniquement
/// localement (pseudo choisi à la première ouverture de l'app, pas de
/// compte) puis être rattaché à un compte Supabase plus tard, d'où la
/// distinction [localUuid] / [remoteId] déjà vue sur [Segment] et [Trace].
@collection
class Utilisateur implements Syncable {
  Utilisateur();

  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  /// Correspond à `auth.users.id` côté Supabase une fois le compte créé.
  @override
  String? remoteId;

  String pseudo = '';
  String? email;
  String? avatarUrl;

  /// `true` pour l'unique enregistrement représentant l'utilisateur de CET
  /// appareil ; `false` pour les profils d'autres contributeurs mis en
  /// cache localement (ex : afficher « segment parcouru 12 fois dont par
  /// Marie » sans requête réseau).
  @Index()
  bool isLocalDevice = false;

  int totalDistanceMeters = 0;
  int totalSegmentsContributed = 0;

  /// Poids de confiance (0.0 à 1.0) utilisé côté serveur pour pondérer la
  /// contribution de cet utilisateur au calcul de `reliabilityIndex` des
  /// segments qu'il emprunte. Mis en cache ici en lecture seule.
  double trustLevel = 0.5;

  @override
  @Index()
  @Enumerated(EnumType.ordinal)
  SyncStatus syncStatus = SyncStatus.pending;

  DateTime createdAt = DateTime.now();

  @override
  DateTime updatedAt = DateTime.now();

  DateTime? lastSyncAt;

  @override
  Map<String, dynamic> toSupabaseMap() => {
        'id': remoteId ?? localUuid,
        'local_uuid': localUuid,
        'pseudo': pseudo,
        'email': email,
        'avatar_url': avatarUrl,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
