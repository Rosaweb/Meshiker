import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:isar_community/isar.dart';
import '../../utils/offline_map_download_service.dart';
import '../../utils/settings_service.dart';
import '../../database/isar_service.dart';
import '../../models/offline_map/offline_map.dart';

// SUPABASE_URL / SUPABASE_ANON_KEY sont injectés au build via
// `--dart-define-from-file=env.json` (cf. env.example.json). Sans eux, les
// sources passant par l'Edge Function proxy (Suède, Finlande) ne
// s'afficheront pas — même limitation que la météo ou l'assistant IA.
const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

// En-têtes envoyés avec chaque requête de tuile passant par l'Edge Function
// `map-tile-proxy` (verify_jwt = false côté fonction, mais la passerelle
// Supabase attend malgré tout la clé anonyme). La clé API réelle du
// fournisseur (Lantmäteriet / MML) reste un secret serveur, jamais ici.
const Map<String, String> _proxyAuthHeaders = {
  'apikey': _supabaseAnonKey,
  'Authorization': 'Bearer $_supabaseAnonKey',
};

/// Emprise géographique d'une source de tuiles à couverture nationale
/// (USGS, Kartverket…). `null` sur une [MapSourceInfo] = disponible partout
/// (cas des fonds génériques OSM / satellite).
class MapBounds {
  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  const MapBounds({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
  });

  bool contains(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;
}

class MapSourceInfo {
  final String id;
  final String name;
  final String url;
  final String description;

  // --- Champs cartes nationales (rétro-compatibles : valeurs par défaut
  // neutres pour les sources génériques existantes). ---

  /// Emprise géographique. `null` = fond de carte proposé partout. Sinon la
  /// source n'est retenue que si le centre de la carte tombe dedans (voir
  /// [MapStyle.resolveTileSource]) — « source bonus déclenchée par zone ».
  final MapBounds? bounds;

  /// Mention légale à afficher tant que cette source est active (widget
  /// d'attribution unique de [MapScreen]). `null` = aucune mention requise.
  final String? attributionText;

  /// Code licence indicatif (`CC-BY-4.0`, `CC0`, `PUBLIC-DOMAIN`…), pour la
  /// doc / l'écran « Mes cartes ». Pas de logique métier dessus.
  final String? licenseCode;

  /// `false` = le téléchargement hors-ligne est refusé sur cette source
  /// (`OfflineMapDownloadService`) tant qu'une confirmation légale écrite
  /// n'est pas obtenue (Kartverket : zone grise Geovekst zoom 12-20 ;
  /// MML : CC BY 4.0 couvre l'affichage, pas confirmé pour le cache). Le
  /// rendu en ligne, lui, reste autorisé.
  final bool cacheAllowedOffline;

  /// En-têtes HTTP additionnels pour chaque requête de tuile (réseau ET
  /// téléchargement hors-ligne). Utilisé pour la clé anonyme Supabase des
  /// sources passant par l'Edge Function proxy. `const {}` par défaut.
  final Map<String, String> httpHeaders;

  /// Deuxième calque de tuiles empilé PAR-DESSUS [url] (mêmes placeholders
  /// `{z}/{x}/{y}`). `null` = un seul calque. Utilisé quand un fond est
  /// servi en deux services distincts — géométrie + étiquettes — comme le
  /// fond canadien CBMT (RNCan). Le calque d'étiquettes est un PNG
  /// transparent.
  final String? overlayUrl;

  /// Niveau de zoom maximal réellement servi par la source. Au-delà,
  /// flutter_map agrandit la dernière tuile disponible au lieu de demander
  /// des tuiles inexistantes (404). `null` = pas de plafond (comportement
  /// historique). Ex: CBMT s'arrête à z15, USGS ~z16.
  final int? maxNativeZoom;

  MapSourceInfo({
    required this.id,
    required this.name,
    required this.url,
    required this.description,
    this.bounds,
    this.attributionText,
    this.licenseCode,
    this.cacheAllowedOffline = true,
    this.httpHeaders = const {},
    this.overlayUrl,
    this.maxNativeZoom,
  });

  /// `true` si [lat]/[lon] tombe dans l'emprise de la source (ou si elle
  /// n'a pas d'emprise = disponible partout).
  bool coversPoint(double lat, double lon) =>
      bounds == null || bounds!.contains(lat, lon);
}

final List<MapSourceInfo> availableSources = [
  MapSourceInfo(
    id: 'osm_standard',
    name: 'OpenStreetMap',
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    description: 'Carte routière et sentiers standard.',
  ),
  MapSourceInfo(
    id: 'opentopo',
    name: 'OpenTopoMap',
    url: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    description: 'Carte topographique avec courbes de niveau.',
  ),
  MapSourceInfo(
    id: 'cyclosm',
    name: 'CyclOSM',
    url: 'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
    description: 'Orientée vélo et relief accentué.',
  ),
  MapSourceInfo(
    id: 'google_sat',
    name: 'Google Satellite',
    url: 'https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}',
    description: 'Vue satellite mondiale par Google.',
  ),
  MapSourceInfo(
    id: 'arcgis_sat',
    name: 'ArcGIS Satellite',
    url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    description: 'Imagerie mondiale haute résolution ArcGIS.',
  ),

  // --- Cartes topographiques nationales (déclenchées par zone) ---
  // Le serveur attend l'ordre z/y/x dans l'URL ; flutter_map et
  // OfflineMapDownloadService substituent {x}/{y} par position, donc écrire
  // le gabarit « {z}/{y}/{x} » suffit — aucun TileProvider spécifique.
  MapSourceInfo(
    id: 'usgs_topo',
    name: 'USGS Topo (États-Unis)',
    // Endpoint tuiles ArcGIS REST (même forme que arcgis_sat, plus fiable
    // que le WMTS KVP). Zoom max ~16. Domaine public, aucun compte.
    url:
        'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}',
    description: 'Cartes topographiques officielles USA (The National Map).',
    bounds: const MapBounds(
        minLat: 15.0, maxLat: 72.0, minLon: -170.0, maxLon: -64.0),
    attributionText:
        'Map services and data available from U.S. Geological Survey, National Geospatial Program.',
    licenseCode: 'PUBLIC-DOMAIN',
  ),
  MapSourceInfo(
    id: 'kartverket_topo',
    name: 'Kartverket (Norvège)',
    url:
        'https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png',
    description: 'Carte topographique nationale norvégienne.',
    bounds: const MapBounds(
        minLat: 57.0, maxLat: 81.5, minLon: 3.0, maxLon: 35.0),
    attributionText: '© Kartverket',
    licenseCode: 'CC-BY-4.0',
    // Zone grise Geovekst (zoom 12-20) : cache hors-ligne bloqué tant que
    // Kartverket n'a pas confirmé le périmètre par écrit.
    cacheAllowedOffline: false,
  ),
  MapSourceInfo(
    id: 'lantmateriet_topowebb',
    name: 'Lantmäteriet (Suède)',
    // Passe par l'Edge Function proxy : la fonction injecte le token
    // Lantmäteriet et remet l'URL amont en ordre z/y/x. Le client envoie
    // toujours {z}/{x}/{y}.
    url:
        '$_supabaseUrl/functions/v1/map-tile-proxy/lantmateriet/{z}/{x}/{y}.png',
    description: 'Carte topographique nationale suédoise (Topowebb).',
    bounds: const MapBounds(
        minLat: 55.0, maxLat: 69.5, minLon: 10.5, maxLon: 24.5),
    attributionText: '© Lantmäteriet',
    licenseCode: 'CC0',
    httpHeaders: _proxyAuthHeaders,
  ),
  MapSourceInfo(
    id: 'mml_maastokartta',
    name: 'Maanmittauslaitos (Finlande)',
    url: '$_supabaseUrl/functions/v1/map-tile-proxy/mml/{z}/{x}/{y}.png',
    description: 'Carte topographique nationale finlandaise (Maastokartta).',
    bounds: const MapBounds(
        minLat: 59.5, maxLat: 70.5, minLon: 19.0, maxLon: 32.0),
    attributionText: '© Maanmittauslaitos',
    licenseCode: 'CC-BY-4.0',
    // CC BY 4.0 confirmé pour l'affichage, pas pour le cache hors-ligne.
    cacheAllowedOffline: false,
    httpHeaders: _proxyAuthHeaders,
  ),
  MapSourceInfo(
    id: 'ign_france',
    name: 'Plan IGN (France)',
    // Plan IGN v2 servi en accès libre par la Géoplateforme IGN
    // (`data.geopf.fr`), sans clé ni compte — TileMatrixSet `PM` = grille
    // Web Mercator standard, donc XYZ classique (TILEMATRIX=z, TILEROW=y,
    // TILECOL=x, substitués par nom). SCAN25 (cartes de rando au 1:25 000)
    // reste, lui, sur abonnement — cf. section « Cartes IGN » de « Mon
    // compte », affichée seulement quand cette source est visible.
    url:
        'https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2&STYLE=normal&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/png',
    description:
        'Plan IGN v2 — cartographie de référence de l\'IGN (Géoplateforme, accès libre).',
    bounds: const MapBounds(
        minLat: 41.0, maxLat: 51.6, minLon: -5.5, maxLon: 9.8),
    attributionText: '© IGN',
    licenseCode: 'ETALAB-2.0',
    maxNativeZoom: 18,
  ),
  MapSourceInfo(
    id: 'cbmt_canada',
    name: 'Canada Base Map (RNCan)',
    // NRCan publie CBMT en tuiles raster PRÉ-RENDUES aussi en EPSG:3857
    // (grille Web Mercator standard, origine et résolutions identiques à
    // OSM) : `CBMT_CBCT_GEOM_3857` = géométrie (routes, hydro, relief),
    // `CBCT_TXT_3857` = étiquettes en français (PNG transparent). Aucune
    // conversion Lambert / provider spécifique nécessaire — c'est un XYZ
    // classique, comme `arcgis_sat`. Tuiles servies jusqu'à z15.
    url:
        'https://maps-cartes.services.geo.ca/server2_serveur2/rest/services/BaseMaps/CBMT_CBCT_GEOM_3857/MapServer/tile/{z}/{y}/{x}',
    overlayUrl:
        'https://maps-cartes.services.geo.ca/server2_serveur2/rest/services/BaseMaps/CBCT_TXT_3857/MapServer/tile/{z}/{y}/{x}',
    description:
        'Fond topographique officiel du Canada (Ressources naturelles Canada), étiquettes en français.',
    bounds: const MapBounds(
        minLat: 41.0, maxLat: 84.0, minLon: -141.5, maxLon: -52.0),
    attributionText: '© Ressources naturelles Canada',
    licenseCode: 'OGL-CANADA',
    // v1 : affichage en ligne uniquement (cf. spec-fond-carte-cbmt-canada).
    cacheAllowedOffline: false,
    maxNativeZoom: 15,
  ),
];

class MapsSettingsScreen extends StatelessWidget {
  const MapsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Container(
        color: Colors.black.withValues(alpha: 0.85),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Mes cartes'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Fonds de carte'),
                Tab(text: 'Hors ligne'),
              ],
              indicatorColor: Colors.greenAccent,
              labelColor: Colors.greenAccent,
              unselectedLabelColor: Colors.white70,
            ),
          ),
          body: const TabBarView(
            children: [
              _OnlineSourcesTab(),
              _OfflineMapsTab(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ligne d'aide affichée sous une source à emprise nationale dans « Mes
/// cartes » : rappelle qu'elle ne s'affiche que sur sa zone, sa licence, et
/// l'éventuelle indisponibilité du téléchargement hors-ligne.
String _regionalHint(MapSourceInfo source) {
  const licenseLabels = {
    'PUBLIC-DOMAIN': 'domaine public',
    'CC0': 'CC0',
    'CC-BY-4.0': 'CC BY 4.0',
    'OGL-CANADA': 'OGL Canada',
    'ETALAB-2.0': 'Licence Ouverte',
  };
  final license = licenseLabels[source.licenseCode] ?? source.licenseCode;
  final buffer = StringBuffer('Carte régionale');
  if (license != null) buffer.write(' ($license)');
  buffer.write(' — s\'affiche uniquement sur sa zone de couverture.');
  if (!source.cacheAllowedOffline) {
    buffer.write(' Téléchargement hors ligne indisponible.');
  }
  return buffer.toString();
}

/// Onglet « Fonds de carte » de « Mes cartes », en deux sections :
///
/// 1. **Cartes affichées** : les fonds proposés par défaut (+ la carte
///    nationale du pays de l'utilisateur, semence unique côté
///    `SettingsService`). La case à cocher y sélectionne les favoris du
///    bouton MAP (max 3, l'ordre = priorité), comportement historique.
/// 2. **Gérer les fonds de carte** (masquée, dépliée par un lien en bas de
///    la section 1) : la liste intégrale. La case à cocher y décide
///    seulement quelles cartes apparaissent dans la section 1 — aucun lien
///    avec le bouton MAP. Décocher une carte favorite la retire aussi des
///    favoris (`SettingsService.setVisibleMaps`).
class _OnlineSourcesTab extends StatefulWidget {
  const _OnlineSourcesTab();

  @override
  State<_OnlineSourcesTab> createState() => _OnlineSourcesTabState();
}

class _OnlineSourcesTabState extends State<_OnlineSourcesTab> {
  bool _managing = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        final visibleSources = availableSources
            .where((s) => settings.visibleMapIds.contains(s.id))
            .toList();

        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'Cochez jusqu\'à 3 cartes favorites. L\'ordre détermine la priorité du bouton MAP.',
                style: TextStyle(color: Colors.white38),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  // --- Section 1 : cartes affichées ---
                  for (final source in visibleSources)
                    _sourceTile(
                        settings: settings,
                        source: source,
                        isFavoriteSection: true),

                  // --- Lien vers la section 2 ---
                  ListTile(
                    leading: Icon(
                      _managing ? Icons.expand_less : Icons.tune,
                      color: Colors.greenAccent,
                    ),
                    title: Text(
                      _managing
                          ? 'Masquer les fonds de carte'
                          : 'Gérer les fonds de carte',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onTap: () => setState(() => _managing = !_managing),
                  ),

                  // --- Section 2 : quelles cartes afficher en section 1 ---
                  if (_managing) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'Cochez les fonds de carte à faire apparaître ci-dessus. '
                        'Sans effet sur le bouton MAP.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                    for (final source in availableSources)
                      _sourceTile(
                          settings: settings,
                          source: source,
                          isFavoriteSection: false),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sourceTile({
    required SettingsService settings,
    required MapSourceInfo source,
    required bool isFavoriteSection,
  }) {
    final favIndex = settings.favoriteMapIds.indexOf(source.id);
    final isFavorite = favIndex != -1;
    final checked = isFavoriteSection
        ? isFavorite
        : settings.visibleMapIds.contains(source.id);

    return ListTile(
      isThreeLine: source.bounds != null,
      title: Text(source.name, style: const TextStyle(color: Colors.white)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(source.description,
              style: const TextStyle(color: Colors.white70)),
          // Fond de carte national : ne s'affiche que sur sa zone de
          // couverture (sinon fond générique). Indiqué pour éviter la
          // surprise « j'ai choisi USGS mais je vois de l'OSM ».
          if (source.bounds != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _regionalHint(source),
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFavoriteSection && isFavorite)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: Colors.greenAccent.withValues(alpha: 0.5)),
              ),
              child: Text(
                'Priorité ${favIndex + 1}',
                style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
          Checkbox(
            value: checked,
            onChanged: (value) => isFavoriteSection
                ? _toggleFavorite(settings, source.id, value == true)
                : _toggleVisible(settings, source.id, value == true),
            checkColor: Colors.black,
            activeColor: Colors.greenAccent,
            side: const BorderSide(color: Colors.white38),
          ),
        ],
      ),
    );
  }

  void _toggleFavorite(SettingsService settings, String id, bool add) {
    final current = List<String>.from(settings.favoriteMapIds);
    if (add) {
      if (current.contains(id) || current.length >= 3) return;
      current.add(id);
    } else {
      current.remove(id);
    }
    settings.setFavoriteMaps(current);
  }

  void _toggleVisible(SettingsService settings, String id, bool add) {
    final current = List<String>.from(settings.visibleMapIds);
    if (add) {
      if (!current.contains(id)) current.add(id);
    } else {
      current.remove(id);
      if (current.isEmpty) return; // toujours au moins une carte affichée
    }
    settings.setVisibleMaps(current);
  }
}

class _OfflineMapsTab extends StatelessWidget {
  const _OfflineMapsTab();

  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    settings.startMapCreation();
                    Navigator.pop(context); // Close panels to show map
                  },
                  icon: const Icon(Icons.add_location_alt),
                  label: const Text('Créer une carte'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    // FileType.custom + allowedExtensions plante sur
                    // certains appareils Android avec "Unsupported filter"
                    // dès que l'extension n'a pas de type MIME enregistré
                    // par le système (cas de .mbtiles) — on filtre donc
                    // nous-mêmes après coup, comme suggéré par le plugin.
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.any,
                    );
                    final path = result?.files.single.path;
                    if (path == null) return;
                    if (!path.toLowerCase().endsWith('.mbtiles')) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Sélectionnez un fichier .mbtiles')),
                        );
                      }
                      return;
                    }
                    // TODO: l'import effectif (copie + enregistrement en
                    // OfflineMap) n'est pas encore implémenté — le
                    // téléchargement de "Créer une carte" est lui-même un
                    // mock pour le moment (cf. _showSaveDialog).
                  },
                  icon: const Icon(Icons.file_download),
                  label: const Text('Importer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<OfflineMap>>(
            stream: isar.isar.offlineMaps.where().watch(fireImmediately: true),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final maps = snapshot.data!;

              if (maps.isEmpty) {
                return const Center(
                  child: Text('Aucune carte hors ligne.', style: TextStyle(color: Colors.white38)),
                );
              }

              return ListView.builder(
                itemCount: maps.length,
                itemBuilder: (context, index) {
                  final map = maps[index];
                  final sizeMb = (map.sizeBytes / (1024 * 1024)).toStringAsFixed(1);
                  final description = map.description;
                  // Téléchargement coupé en route (app tuée, perte réseau)
                  // avant d'atteindre 100% ou d'être marqué en erreur --
                  // distinct de isError (échec confirmé) et de isDownloading
                  // (en cours dans CETTE session). Voir
                  // IsarService.resetStuckOfflineMapDownloads.
                  final isInterrupted = !map.isDownloading &&
                      !map.isError &&
                      map.downloadProgress > 0 &&
                      map.downloadProgress < 1.0;

                  return ListTile(
                    leading: const Icon(Icons.map, color: Colors.greenAccent),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            map.name,
                            style: const TextStyle(color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        Text(
                          '  •  $sizeMb MB',
                          style: const TextStyle(color: Colors.white38),
                        ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (description != null && description.isNotEmpty)
                          Text(
                            description,
                            style: const TextStyle(color: Colors.white38),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        if (map.isDownloading)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: map.downloadProgress,
                                    backgroundColor: Colors.white10,
                                    valueColor: const AlwaysStoppedAnimation(Colors.greenAccent),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${(map.downloadProgress * 100).round()}%',
                                  style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        if (map.isError)
                          const Text('Erreur. Appuyez pour reprendre.', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                        if (isInterrupted)
                          const Text('Téléchargement interrompu. Appuyez pour reprendre.', style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                      ],
                    ),
                    onTap: () {
                      if ((map.isError || isInterrupted) && !map.isDownloading) {
                        OfflineMapDownloadService(isarService: isar).download(
                            map,
                            headers: const {'User-Agent': 'Meshiker/1.0'});
                        return;
                      }
                      if (map.isDownloading) return;
                      _showMapDetailsDialog(context, isar, map);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _showMapDetailsDialog(BuildContext context, IsarService isar, OfflineMap map) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        map.name,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(dialogContext),
                      tooltip: 'Fermer',
                    ),
                  ],
                ),
                if (map.description != null && map.description!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    map.description!,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      await OfflineMapDownloadService(isarService: isar)
                          .deleteFiles(map.localUuid);
                      await isar.deleteOfflineMap(map.id);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    },
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    label: const Text('Supprimer', style: TextStyle(color: Colors.redAccent)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
