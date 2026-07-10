import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:mbtiles/mbtiles.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_mbtiles/vector_map_tiles_mbtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// Source de tuiles vectorielles 100% locale, pour flutter_map.
///
/// Choix de packages (verifies avant integration) :
/// - flutter_map : le moteur de carte lui-meme, le plus utilise de
///   l'ecosysteme Flutter open source.
/// - vector_map_tiles : plugin flutter_map qui sait afficher des tuiles
///   vectorielles (stylees avec un theme type Mapbox/MapLibre), au lieu
///   de simples tuiles raster.
/// - vector_map_tiles_mbtiles (+ mbtiles) : fournisseur de tuiles
///   vectorielles lisant un fichier .mbtiles LOCAL (SQLite contenant des
///   tuiles au format PBF/MVT) -- c'est la brique qui rend tout ceci
///   utilisable "100% deconnecte" (section intro du brief) : aucune tuile
///   n'est jamais telechargee a l'execution.
///
/// Ce que cette classe NE fournit PAS : le fichier .mbtiles lui-meme (les
/// donnees cartographiques vectorielles reelles pour la ou les regions
/// couvertes par l'app) et le fichier de style JSON (couleurs, epaisseurs,
/// ordre des calques) sont des ASSETS a produire separement (ex : export
/// depuis OpenMapTiles, TileMill/Maputnik pour le style) -- aucun outil ne
/// peut generer des donnees cartographiques reelles a la place d'une
/// vraie source (OSM, IGN...). Cette classe se contente de les CHARGER.
///
/// Point de vigilance : c'est la partie la MOINS verifiable sans
/// environnement Flutter reel de tout ce projet : l'API exacte de
/// ThemeReader pour un style local (par opposition a un style charge
/// depuis une URL, le cas le plus documente par le package) peut differer
/// legerement de ce qui suit selon la version installee. Avant mise en
/// production, comparez avec l'exemple officiel du depot vector_map_tiles.
class VectorTileSource {
  const VectorTileSource({this.theme, required this.tileProviders});

  final vtr.Theme? theme;
  final TileProviders tileProviders;

  /// Construit la source a partir d'un fichier .mbtiles et d'un style
  /// JSON, tous deux embarques localement (assets de l'app ou fichiers
  /// deja telecharges dans le stockage de l'application).
  static Future<VectorTileSource> fromLocalFiles({
    required String mbTilesPath,
    required String styleJsonAssetPath,
    String providerId = 'openmaptiles',
    bool gzip = false,
  }) async {
    final mbtiles = MbTiles(mbtilesPath: mbTilesPath, gzip: gzip);
    final provider = MbTilesVectorTileProvider(
      mbtiles: mbtiles,
    );

    final styleJsonString = await rootBundle.loadString(styleJsonAssetPath);
    final theme = vtr.ThemeReader().read(json.decode(styleJsonString));

    return VectorTileSource(
      theme: theme,
      tileProviders: TileProviders({providerId: provider}),
    );
  }
}
