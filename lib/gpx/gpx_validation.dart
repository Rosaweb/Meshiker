import 'dart:io';

/// Limites et règles de conformité appliquées à tout fichier GPX/KML
/// importé, quelle que soit sa provenance (import manuel, scan de
/// dossier `GpxScannerService`, réception d'un partage
/// `TraceShareService`) : [GpxParser] et [KmlParser] sont le point de
/// passage commun à tous ces chemins, c'est donc là que ces règles sont
/// appliquées.
///
/// Avant ce fichier, rien ne bornait la taille d'un GPX/KML importé ni
/// la validité de ses coordonnées : un fichier corrompu (ou construit
/// pour nuire — taille énorme, coordonnées `NaN`/`Infinity`/hors plage)
/// pouvait se frayer un chemin jusqu'au moteur de segmentation et à
/// l'affichage carte sans qu'aucune couche ne s'en aperçoive.
class GpxLimits {
  const GpxLimits._();

  /// Taille maximale acceptée pour un fichier/contenu GPX ou KML, en
  /// octets. Dimensionnée pour couvrir le cas réel d'un thru-hiker qui
  /// importe plusieurs milliers de km (PCT, GR ininterrompu...)
  /// enregistrés en un seul fichier continu, y compris au format verbeux
  /// (lat/lon/ele/time indentés, ~140 octets/point) : à 100 Mo, ça
  /// représente ~750 000 points même dans ce format peu compact, et
  /// plusieurs millions en format compact. Ça reste borné (contrairement
  /// à "pas de limite du tout") pour éviter qu'un fichier corrompu ou
  /// hostile ne fasse charger un contenu arbitrairement gros en mémoire
  /// avant que `XmlDocument.parse` ne construise l'arbre DOM par-dessus.
  static const maxContentBytes = 100 * 1024 * 1024; // 100 Mo

  /// Nombre maximal de `<trkpt>`/coordonnées de tracé acceptées après
  /// parsing. Volontairement très au-dessus de tout usage réel — y
  /// compris un enregistrement continu de plusieurs mois à 1 point/
  /// seconde (voir maxContentBytes pour le raisonnement complet) — pour
  /// ne jamais bloquer une trace de thru-hiking légitime ; ce n'est
  /// qu'un filet de sécurité contre un fichier dégénéré (des millions de
  /// points quasi vides pour maximiser leur nombre à taille de fichier
  /// égale) qui ferait exploser le temps de calcul du découpage en
  /// segments.
  static const maxTrackPoints = 3000000;

  static const maxWaypoints = 100000;

  /// Vérifie la taille d'un fichier GPX/KML avant même de le lire en
  /// mémoire (`readAsString` chargerait tout le fichier d'un coup, y
  /// compris un fichier de plusieurs centaines de Mo déposé par erreur
  /// ou volontairement dans le dossier surveillé par
  /// `GpxScannerService`).
  static Future<void> checkFileSize(File file) async {
    final length = await file.length();
    if (length > maxContentBytes) {
      throw GpxValidationException(
        'Fichier trop volumineux (${(length / (1024 * 1024)).toStringAsFixed(1)} Mo, '
        'maximum ${maxContentBytes ~/ (1024 * 1024)} Mo).',
      );
    }
  }

  /// Même contrôle que [checkFileSize] mais sur un contenu déjà en
  /// mémoire (import depuis une chaîne, ex. GPX téléchargé via un lien de
  /// partage). `content.length` compte des unités UTF-16 : un majorant
  /// suffisant du nombre d'octets pour du texte GPX/KML, très
  /// majoritairement ASCII.
  static void checkContentLength(String content) {
    if (content.length > maxContentBytes) {
      throw const GpxValidationException('Contenu GPX/KML trop volumineux.');
    }
  }

  static void checkPointCounts({required int trackPoints, required int waypoints}) {
    if (trackPoints > maxTrackPoints || waypoints > maxWaypoints) {
      throw const GpxValidationException(
        'Fichier GPX/KML hors limites : trop de points pour être importé.',
      );
    }
  }

  /// Vrai si [value] est une latitude exploitable : un nombre fini dans
  /// la plage `[-90, 90]`. Rejette `NaN`/`Infinity`, que
  /// `double.tryParse` accepte pourtant (`double.tryParse('NaN')` renvoie
  /// bien `NaN`, `double.tryParse('Infinity')` renvoie `double.infinity`)
  /// et qui corrompraient silencieusement les calculs géométriques en
  /// aval (distance, bounding box, affichage carte) si on les laissait
  /// passer.
  static bool isValidLatitude(double value) => value.isFinite && value >= -90 && value <= 90;

  static bool isValidLongitude(double value) => value.isFinite && value >= -180 && value <= 180;

  /// Seul un nombre fini est exigé ici (pas de plage min/max) : une
  /// altitude aberrante mais finie reste un problème de qualité de
  /// données, pas de sécurité — elle n'a pas le même pouvoir de nuisance
  /// qu'un `NaN`/`Infinity` qui se propage dans les calculs de dénivelé.
  static bool isValidElevation(double value) => value.isFinite;
}

/// Levée quand un fichier GPX/KML ne respecte pas les limites de
/// [GpxLimits]. Traitée comme n'importe quelle autre erreur de parsing
/// par les appelants existants (`GpxImportService`, `GpxScannerService`,
/// `TraceShareService`), qui savent déjà attraper un `FormatException` de
/// parsing XML et l'afficher/logger proprement.
class GpxValidationException implements Exception {
  const GpxValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}
