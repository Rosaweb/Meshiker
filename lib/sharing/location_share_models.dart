/// Modes de partage de position — voir spec-partage-position-live-tracking.md
/// §2/§3. Détermine la fréquence d'émission de position.
enum LocationShareMode {
  manual,
  auto,
  live;

  String get sqlValue => name;

  static LocationShareMode fromSql(String value) =>
      LocationShareMode.values.firstWhere((m) => m.sqlValue == value);
}

/// Canaux de diffusion (sélection multiple pour `location_shares.channels`)
/// ET valeurs possibles de `location_share_members.channel` (qui ajoute
/// `accountsOnly` : un membre ajouté par recherche de pseudo quand
/// `web_access = 'accounts_only'`, jamais proposé dans le sélecteur de
/// diffusion lui-même) — spec §2/§3/§4. `sms` reste visible mais grisé
/// "Bientôt disponible" côté UI (non construit en v1) ; `web` est grisé
/// pour ce chantier tant que meshiker-web n'existe pas (voir plan
/// d'implémentation), donc `accountsOnly` reste inerte en pratique.
enum LocationShareChannel {
  web,
  email,
  sms,
  app,
  accountsOnly;

  String get sqlValue => this == LocationShareChannel.accountsOnly ? 'accounts_only' : name;

  static LocationShareChannel fromSql(String value) =>
      value == 'accounts_only' ? LocationShareChannel.accountsOnly : LocationShareChannel.values.firstWhere((c) => c.sqlValue == value);
}

/// Modèle de réciprocité App-to-app — spec §2/§3. Toujours [unilateral]
/// côté modèle pour un partage Manuel, non exposé dans l'UI pour ce mode.
enum LocationShareReciprocity {
  unilateral,
  bilateral,
  multilateral;

  String get sqlValue => name;

  static LocationShareReciprocity fromSql(String value) =>
      LocationShareReciprocity.values.firstWhere((r) => r.sqlValue == value);
}

/// Niveau d'accès web — spec §3. `accountsOnly` et `password` restent
/// inertes tant que meshiker-web n'existe pas (voir plan d'implémentation).
enum LocationShareWebAccess {
  public,
  password,
  accountsOnly;

  String get sqlValue {
    switch (this) {
      case LocationShareWebAccess.public:
        return 'public';
      case LocationShareWebAccess.password:
        return 'password';
      case LocationShareWebAccess.accountsOnly:
        return 'accounts_only';
    }
  }

  static LocationShareWebAccess fromSql(String value) {
    switch (value) {
      case 'password':
        return LocationShareWebAccess.password;
      case 'accounts_only':
        return LocationShareWebAccess.accountsOnly;
      default:
        return LocationShareWebAccess.public;
    }
  }
}

/// Statut d'une invitation App-to-app — spec §4/§7.2.
enum LocationShareInviteStatus {
  pending,
  accepted,
  declined;

  static LocationShareInviteStatus fromSql(String value) =>
      LocationShareInviteStatus.values.firstWhere((s) => s.name == value);
}

/// Un partage de position — miroir de `public.location_shares`
/// (voir supabase/schema.sql).
class LocationShare {
  LocationShare({
    required this.id,
    required this.ownerId,
    this.label,
    required this.mode,
    required this.channels,
    required this.reciprocity,
    this.liveIntervalSeconds,
    this.autoTimes,
    required this.historyEnabled,
    required this.historyGlobal,
    required this.webAccess,
    required this.shareToken,
    required this.isActive,
    required this.startedAt,
    this.endedAt,
    required this.expiresAt,
  });

  factory LocationShare.fromMap(Map<String, dynamic> map) => LocationShare(
        id: map['id'] as String,
        ownerId: map['owner_id'] as String,
        label: map['label'] as String?,
        mode: LocationShareMode.fromSql(map['mode'] as String),
        channels: ((map['channels'] as List<dynamic>?) ?? const [])
            .map((c) => LocationShareChannel.fromSql(c as String))
            .toSet(),
        reciprocity: LocationShareReciprocity.fromSql(map['reciprocity'] as String),
        liveIntervalSeconds: map['live_interval_seconds'] as int?,
        autoTimes: (map['auto_times'] as List<dynamic>?)?.map((t) => t as String).toList(),
        historyEnabled: map['history_enabled'] as bool? ?? false,
        historyGlobal: map['history_global'] as bool? ?? false,
        webAccess: LocationShareWebAccess.fromSql(map['web_access'] as String),
        shareToken: map['share_token'] as String,
        isActive: map['is_active'] as bool? ?? false,
        startedAt: DateTime.parse(map['started_at'] as String),
        endedAt: map['ended_at'] == null ? null : DateTime.parse(map['ended_at'] as String),
        expiresAt: DateTime.parse(map['expires_at'] as String),
      );

  final String id;
  final String ownerId;
  final String? label;
  final LocationShareMode mode;
  final Set<LocationShareChannel> channels;
  final LocationShareReciprocity reciprocity;
  final int? liveIntervalSeconds;
  final List<String>? autoTimes; // "HH:mm:ss", tel que renvoyé par Postgres
  final bool historyEnabled;
  final bool historyGlobal;
  final LocationShareWebAccess webAccess;
  final String shareToken;
  final bool isActive;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime expiresAt;

  bool isOwnedBy(String userId) => ownerId == userId;
}

/// Un membre d'un partage — miroir de `public.location_share_members`.
class LocationShareMember {
  LocationShareMember({
    required this.id,
    required this.shareId,
    this.userId,
    this.pseudo,
    required this.channel,
    this.contact,
    required this.inviteStatus,
    this.inviteRespondedAt,
    required this.historyConsent,
    this.historyConsentAt,
  });

  factory LocationShareMember.fromMap(Map<String, dynamic> map) => LocationShareMember(
        id: map['id'] as String,
        shareId: map['share_id'] as String,
        userId: map['user_id'] as String?,
        // Selon la requête : soit un alias plat `pseudo` posé à la main,
        // soit l'objet imbriqué renvoyé par l'embedding PostgREST
        // `profiles(pseudo)` (relation plusieurs-vers-un → objet, pas liste).
        pseudo: map['pseudo'] as String? ??
            (map['profiles'] as Map<String, dynamic>?)?['pseudo'] as String?,
        channel: LocationShareChannel.fromSql(map['channel'] as String),
        contact: map['contact'] as String?,
        inviteStatus: LocationShareInviteStatus.fromSql(map['invite_status'] as String),
        inviteRespondedAt: map['invite_responded_at'] == null
            ? null
            : DateTime.parse(map['invite_responded_at'] as String),
        historyConsent: map['history_consent'] as bool? ?? false,
        historyConsentAt: map['history_consent_at'] == null
            ? null
            : DateTime.parse(map['history_consent_at'] as String),
      );

  final String id;
  final String shareId;
  final String? userId;
  final String? pseudo; // rempli côté client via un join profiles, absent en base
  final LocationShareChannel channel;
  final String? contact;
  final LocationShareInviteStatus inviteStatus;
  final DateTime? inviteRespondedAt;
  final bool historyConsent;
  final DateTime? historyConsentAt;
}

/// Un point de position — miroir de `public.location_pings`.
class LocationPing {
  LocationPing({
    required this.id,
    required this.shareId,
    required this.userId,
    required this.lat,
    required this.lng,
    this.altitude,
    this.speed,
    this.accuracy,
    required this.recordedAt,
  });

  factory LocationPing.fromMap(Map<String, dynamic> map) => LocationPing(
        id: map['id'] as int,
        shareId: map['share_id'] as String,
        userId: map['user_id'] as String,
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
        altitude: (map['altitude'] as num?)?.toDouble(),
        speed: (map['speed'] as num?)?.toDouble(),
        accuracy: (map['accuracy'] as num?)?.toDouble(),
        recordedAt: DateTime.parse(map['recorded_at'] as String),
      );

  final int id;
  final String shareId;
  final String userId;
  final double lat;
  final double lng;
  final double? altitude;
  final double? speed;
  final double? accuracy;
  final DateTime recordedAt;
}

/// Résultat de `join_location_share` — de quoi afficher l'écran
/// d'invitation avant que le membre n'accepte (spec §7.2).
class LocationShareJoinResult {
  const LocationShareJoinResult({
    required this.shareId,
    required this.label,
    required this.ownerPseudo,
    required this.mode,
    required this.reciprocity,
    required this.historyGlobal,
    required this.memberId,
    required this.inviteStatus,
  });

  factory LocationShareJoinResult.fromMap(Map<String, dynamic> map) => LocationShareJoinResult(
        shareId: map['share_id'] as String,
        label: map['label'] as String?,
        ownerPseudo: map['owner_pseudo'] as String? ?? '',
        mode: LocationShareMode.fromSql(map['mode'] as String),
        reciprocity: LocationShareReciprocity.fromSql(map['reciprocity'] as String),
        historyGlobal: map['history_global'] as bool? ?? false,
        memberId: map['member_id'] as String,
        inviteStatus: LocationShareInviteStatus.fromSql(map['invite_status'] as String),
      );

  final String shareId;
  final String? label;
  final String ownerPseudo;
  final LocationShareMode mode;
  final LocationShareReciprocity reciprocity;
  final bool historyGlobal;
  final String memberId;
  final LocationShareInviteStatus inviteStatus;
}

/// Erreur de partage de position destinée à être affichée telle quelle à
/// l'utilisateur (message déjà en français). `isPremiumRequired` permet à
/// l'UI de déclencher l'upsell RevenueCat plutôt qu'un simple message
/// d'erreur générique.
class LocationShareException implements Exception {
  const LocationShareException(this.message, {this.isPremiumRequired = false});

  final String message;
  final bool isPremiumRequired;

  @override
  String toString() => message;
}
