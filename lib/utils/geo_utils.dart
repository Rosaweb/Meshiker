import 'dart:math';

/// Petits utilitaires géographiques 100% locaux (aucune dépendance réseau
/// ni cloud), utilisés pour enrichir un `Segment` au moment de sa
/// création : distance/dénivelé cumulés, bounding box et géohash grossier
/// pour l'indexation locale (voir `Segment.geohashPrefix` et
/// `IsarService.segmentsInViewport`).
class GeoUtils {
  GeoUtils._();

  static const _earthRadiusMeters = 6371000.0;
  static const _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  /// Distance orthodromique (formule de Haversine) entre deux points, en
  /// mètres. Suffisamment précise à l'échelle d'un segment de randonnée
  /// (quelques mètres à quelques kilomètres) sans nécessiter de
  /// bibliothèque géodésique lourde.
  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  static double _degToRad(double deg) => deg * pi / 180;

  /// Encodage géohash (précision configurable ; 5 caractères par défaut,
  /// soit des cellules d'environ 5 km de côté — largement suffisant pour
  /// un pré-filtrage grossier avant comparaison exacte de bounding box).
  ///
  /// Ne remplace évidemment pas un vrai index spatial : côté serveur,
  /// c'est PostGIS (colonne `geometry` + index GIST) qui fait le travail
  /// géométrique précis, y compris la fusion par buffer.
  static String geohash(
    double latitude,
    double longitude, {
    int precision = 5,
  }) {
    var latMin = -90.0, latMax = 90.0;
    var lonMin = -180.0, lonMax = 180.0;
    final buffer = StringBuffer();
    var isEvenBit = true;
    var bit = 0;
    var charBits = 0;

    while (buffer.length < precision) {
      if (isEvenBit) {
        final mid = (lonMin + lonMax) / 2;
        if (longitude >= mid) {
          charBits = (charBits << 1) | 1;
          lonMin = mid;
        } else {
          charBits = charBits << 1;
          lonMax = mid;
        }
      } else {
        final mid = (latMin + latMax) / 2;
        if (latitude >= mid) {
          charBits = (charBits << 1) | 1;
          latMin = mid;
        } else {
          charBits = charBits << 1;
          latMax = mid;
        }
      }
      isEvenBit = !isEvenBit;

      if (bit < 4) {
        bit++;
      } else {
        buffer.write(_base32[charBits]);
        bit = 0;
        charBits = 0;
      }
    }
    return buffer.toString();
  }

  /// Calcule la bounding box (min/max lat/lon) d'une liste de points.
  /// Renvoie `null` si la liste est vide.
  static ({double minLat, double maxLat, double minLon, double maxLon})?
      boundingBox(Iterable<({double lat, double lon})> points) {
    if (points.isEmpty) return null;
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLon = double.infinity, maxLon = -double.infinity;
    for (final p in points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    return (minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
  }

  /// Distance minimale (mètres) entre un point et un polyligne (liste de
  /// points ordonnés), par projection sur un plan tangent local plutôt
  /// que par un calcul géodésique exact.
  ///
  /// Approximation volontaire : à l'échelle d'un segment de randonnée
  /// (de quelques dizaines de mètres à quelques kilomètres), l'erreur
  /// introduite par la projection plane est négligeable devant le buffer
  /// de tolérance utilisé (5-10 m), et le coût de calcul reste minime —
  /// important puisque cette fonction est appelée pour chaque point de
  /// chaque tranche testée lors du découpage GPX.
  static double distancePointToPolylineMeters(
    double lat,
    double lon,
    List<({double lat, double lon})> polyline,
  ) {
    if (polyline.isEmpty) return double.infinity;
    if (polyline.length == 1) {
      return haversineMeters(lat, lon, polyline.first.lat, polyline.first.lon);
    }

    final originLat = polyline.first.lat;
    final originLon = polyline.first.lon;
    const mPerDegLat = 111320.0;
    final mPerDegLon = 111320.0 * cos(_degToRad(originLat));

    ({double x, double y}) toPlane(double la, double lo) => (
          x: (lo - originLon) * mPerDegLon,
          y: (la - originLat) * mPerDegLat,
        );

    final p = toPlane(lat, lon);
    var best = double.infinity;
    for (var i = 0; i < polyline.length - 1; i++) {
      final a = toPlane(polyline[i].lat, polyline[i].lon);
      final b = toPlane(polyline[i + 1].lat, polyline[i + 1].lon);
      final d = _distancePointToSegmentPlane(p, a, b);
      if (d < best) best = d;
    }
    return best;
  }

  static double _distancePointToSegmentPlane(
    ({double x, double y}) p,
    ({double x, double y}) a,
    ({double x, double y}) b,
  ) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final lengthSq = abx * abx + aby * aby;
    var t = lengthSq == 0
        ? 0.0
        : ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq;
    t = t.clamp(0.0, 1.0);
    final projX = a.x + t * abx;
    final projY = a.y + t * aby;
    final dx = p.x - projX;
    final dy = p.y - projY;
    return sqrt(dx * dx + dy * dy);
  }

  /// Dénivelé positif/négatif cumulé à partir d'une liste d'altitudes,
  /// en ignorant les variations plus petites que [noiseThresholdMeters]
  /// (le bruit d'altitude GPS gonfle sinon artificiellement le dénivelé,
  /// parfois de plusieurs centaines de mètres sur une longue trace).
  /// Les altitudes `null` (capteur indisponible) sont simplement
  /// ignorées, sans casser la continuité du calcul.
  static ({double gain, double loss}) elevationGainLoss(
    List<double?> elevations, {
    double noiseThresholdMeters = 2.0,
  }) {
    double gain = 0, loss = 0;
    double? lastStable;
    for (final e in elevations) {
      if (e == null) continue;
      if (lastStable == null) {
        lastStable = e;
        continue;
      }
      final delta = e - lastStable;
      if (delta.abs() >= noiseThresholdMeters) {
        if (delta > 0) {
          gain += delta;
        } else {
          loss += -delta;
        }
        lastStable = e;
      }
    }
    return (gain: gain, loss: loss);
  }

  /// Projette (lat, lon) sur le point le plus proche d'un polyligne, si à
  /// moins de [maxDistanceMeters]. Renvoie, en plus des coordonnées
  /// projetées, l'index du segment de polyligne concerné et le paramètre
  /// d'interpolation `t` (0 à l'extrémité `i`, 1 à l'extrémité `i+1`) —
  /// ces deux informations permettent ensuite d'extraire une sous-portion
  /// du polyligne entre deux points projetés (voir [subPolylineBetween]),
  /// utilisée par le mode planification pour faire "suivre" un tracé
  /// existant à l'itinéraire en cours de dessin (aimant activé).
  static ({double lat, double lon, int segmentIndex, double t})?
      snapToPolyline(
    double lat,
    double lon,
    List<({double lat, double lon})> polyline,
    double maxDistanceMeters,
  ) {
    if (polyline.length < 2) return null;

    final originLat = polyline.first.lat;
    final originLon = polyline.first.lon;
    const mPerDegLat = 111320.0;
    final mPerDegLon = 111320.0 * cos(_degToRad(originLat));

    ({double x, double y}) toPlane(double la, double lo) => (
          x: (lo - originLon) * mPerDegLon,
          y: (la - originLat) * mPerDegLat,
        );
    ({double lat, double lon}) fromPlane(double x, double y) => (
          lat: originLat + y / mPerDegLat,
          lon: originLon + x / mPerDegLon,
        );

    final p = toPlane(lat, lon);
    var bestDist = double.infinity;
    var bestIndex = -1;
    var bestT = 0.0;
    ({double x, double y}) bestPoint = (x: 0, y: 0);

    for (var i = 0; i < polyline.length - 1; i++) {
      final a = toPlane(polyline[i].lat, polyline[i].lon);
      final b = toPlane(polyline[i + 1].lat, polyline[i + 1].lon);
      final abx = b.x - a.x;
      final aby = b.y - a.y;
      final lengthSq = abx * abx + aby * aby;
      var t = lengthSq == 0
          ? 0.0
          : ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq;
      t = t.clamp(0.0, 1.0);
      final projX = a.x + t * abx;
      final projY = a.y + t * aby;
      final dx = p.x - projX;
      final dy = p.y - projY;
      final d = sqrt(dx * dx + dy * dy);
      if (d < bestDist) {
        bestDist = d;
        bestIndex = i;
        bestT = t;
        bestPoint = (x: projX, y: projY);
      }
    }

    if (bestIndex < 0 || bestDist > maxDistanceMeters) return null;
    final snapped = fromPlane(bestPoint.x, bestPoint.y);
    return (lat: snapped.lat, lon: snapped.lon, segmentIndex: bestIndex, t: bestT);
  }

  /// Extrait les sommets d'un polyligne strictement compris entre deux
  /// points préalablement projetés par [snapToPolyline] SUR LE MÊME
  /// polyligne (ne vérifie pas que c'est bien le cas — à l'appelant de
  /// s'en assurer). Gère les deux sens de parcours. Le résultat inclut
  /// les deux extrémités projetées mais aucun sommet du polyligne
  /// au-delà d'elles.
  ///
  /// Sert à faire "suivre" à un itinéraire en cours de dessin (mode
  /// planification, aimant activé) la forme réelle d'un segment déjà
  /// connu, plutôt qu'une ligne droite entre les deux points tapés.
  static List<({double lat, double lon})> subPolylineBetween(
    List<({double lat, double lon})> polyline,
    ({double lat, double lon, int segmentIndex, double t}) from,
    ({double lat, double lon, int segmentIndex, double t}) to,
  ) {
    final result = <({double lat, double lon})>[(lat: from.lat, lon: from.lon)];

    if (from.segmentIndex <= to.segmentIndex) {
      for (var i = from.segmentIndex + 1; i <= to.segmentIndex; i++) {
        result.add((lat: polyline[i].lat, lon: polyline[i].lon));
      }
    } else {
      for (var i = from.segmentIndex; i > to.segmentIndex; i--) {
        result.add((lat: polyline[i].lat, lon: polyline[i].lon));
      }
    }

    result.add((lat: to.lat, lon: to.lon));
    return result;
  }

  /// Calcule la distance totale d'un polyligne en mètres.
  static double polylineLengthMeters(List<({double lat, double lon})> polyline) {
    double total = 0;
    for (int i = 0; i < polyline.length - 1; i++) {
      total += haversineMeters(
        polyline[i].lat, polyline[i].lon,
        polyline[i+1].lat, polyline[i+1].lon,
      );
    }
    return total;
  }

  /// Calcule la distance cumulée jusqu'à un point projeté par [snapToPolyline].
  static double distanceToSnapMeters(
    List<({double lat, double lon})> polyline,
    ({double lat, double lon, int segmentIndex, double t}) snap,
  ) {
    double dist = 0;
    for (int i = 0; i < snap.segmentIndex; i++) {
      dist += haversineMeters(
        polyline[i].lat, polyline[i].lon,
        polyline[i+1].lat, polyline[i+1].lon,
      );
    }
    
    // Ajout de la portion fractionnaire du dernier segment
    dist += haversineMeters(
      polyline[snap.segmentIndex].lat, polyline[snap.segmentIndex].lon,
      snap.lat, snap.lon,
    );
    
    return dist;
  }

  /// Simplifie un polyligne par l'algorithme de Douglas-Peucker (distance
  /// perpendiculaire au segment, projection sur plan tangent local comme
  /// [distancePointToPolylineMeters]) : ne conserve que les sommets dont
  /// l'écart à la corde qu'ils remplaceraient dépasse [toleranceMeters].
  /// Les deux extrémités sont toujours conservées.
  ///
  /// Utilisé par l'assistant IA (analyse terrain, `spec-assistant-terrain-topo.md`)
  /// pour réduire une trace de plusieurs milliers de points GPS à quelques
  /// dizaines de sommets avant de construire une requête Overpass
  /// `around:` — indispensable, sous peine de requêtes trop lourdes ou
  /// rejetées côté serveur (cf. §3.3 de cette spec).
  ///
  /// Implémentation itérative (pile explicite) plutôt que récursive : une
  /// polyligne de plusieurs milliers de points en récursif risquerait un
  /// stack overflow sur un cas adversarial (ex. une trace en ligne quasi
  /// droite où presque aucun point n'est éliminé).
  static List<({double lat, double lon})> simplifyDouglasPeucker(
    List<({double lat, double lon})> polyline,
    double toleranceMeters,
  ) {
    if (polyline.length < 3) return polyline;

    final originLat = polyline.first.lat;
    final originLon = polyline.first.lon;
    const mPerDegLat = 111320.0;
    final mPerDegLon = 111320.0 * cos(_degToRad(originLat));

    ({double x, double y}) toPlane(double la, double lo) => (
          x: (lo - originLon) * mPerDegLon,
          y: (la - originLat) * mPerDegLat,
        );

    final plane = polyline.map((p) => toPlane(p.lat, p.lon)).toList();
    final keep = List<bool>.filled(polyline.length, false);
    keep[0] = true;
    keep[polyline.length - 1] = true;

    final stack = <(int, int)>[(0, polyline.length - 1)];
    while (stack.isNotEmpty) {
      final (start, end) = stack.removeLast();
      if (end - start < 2) continue;

      var maxDist = -1.0;
      var maxIndex = -1;
      for (var i = start + 1; i < end; i++) {
        final d = _distancePointToSegmentPlane(plane[i], plane[start], plane[end]);
        if (d > maxDist) {
          maxDist = d;
          maxIndex = i;
        }
      }

      if (maxIndex != -1 && maxDist > toleranceMeters) {
        keep[maxIndex] = true;
        stack.add((start, maxIndex));
        stack.add((maxIndex, end));
      }
    }

    return [for (var i = 0; i < polyline.length; i++) if (keep[i]) polyline[i]];
  }

  /// Calcule l'azimut (relèvement) entre deux points en degrés (0-360).
  /// 0 = Nord, 90 = Est, 180 = Sud, 270 = Ouest.
  static double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
    final dLon = _degToRad(lon2 - lon1);
    final y = sin(dLon) * cos(_degToRad(lat2));
    final x = cos(_degToRad(lat1)) * sin(_degToRad(lat2)) -
        sin(_degToRad(lat1)) * cos(_degToRad(lat2)) * cos(dLon);
    
    final radians = atan2(y, x);
    return (_radToDeg(radians) + 360) % 360;
  }

  /// Calcule le point atteint en partant de (lat, lon), selon un azimut
  /// (0-360°, 0 = Nord) et une distance en mètres. Inverse de
  /// [bearingDegrees] : utilisé pour prolonger visuellement un relèvement
  /// (visée boussole) au-delà du point visé, et pour tracer une petite
  /// perpendiculaire de part et d'autre d'un point sélectionné. Formule
  /// sphérique standard, précision suffisante à l'échelle d'un écran de
  /// carte de randonnée.
  static ({double lat, double lon}) destinationPoint(
    double lat,
    double lon,
    double bearingDeg,
    double distanceMeters,
  ) {
    final delta = distanceMeters / _earthRadiusMeters;
    final theta = _degToRad(bearingDeg);
    final phi1 = _degToRad(lat);
    final lambda1 = _degToRad(lon);

    final phi2 = asin(
      sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta),
    );
    final lambda2 = lambda1 +
        atan2(
          sin(theta) * sin(delta) * cos(phi1),
          cos(delta) - sin(phi1) * sin(phi2),
        );

    return (lat: _radToDeg(phi2), lon: _radToDeg(lambda2));
  }

  static double _radToDeg(double rad) => rad * 180 / pi;

  /// Convertit un azimut ([bearingDegrees]) en point cardinal français à 8
  /// directions (N, NE, E, SE, S, SO, O, NO) — utilisé par l'assistant IA de
  /// navigation (v2) pour formuler des directions compréhensibles à l'oral
  /// plutôt qu'un nombre de degrés brut.
  static const _compassPoints = ['N', 'NE', 'E', 'SE', 'S', 'SO', 'O', 'NO'];

  static String compassPoint(double bearingDegrees) {
    final normalized = ((bearingDegrees % 360) + 360) % 360;
    final index = ((normalized / 45) + 0.5).floor() % 8;
    return _compassPoints[index];
  }

  // Ellipsoïde WGS84, utilisé par le GPS -- cohérent avec les coordonnées
  // lat/lon manipulées partout ailleurs dans l'app.
  static const _utmA = 6378137.0;
  static const _utmF = 1 / 298.257223563;
  static const _utmK0 = 0.9996;

  /// Convertit une coordonnée WGS84 (lat/lon) en UTM (zone, hémisphère,
  /// easting/northing en mètres). Formule Transverse Mercator standard ;
  /// ne gère pas les exceptions de zones norvégiennes/Svalbard, sans
  /// incidence pour un usage randonnée.
  static ({int zone, String hemisphere, double easting, double northing})
      latLonToUtm(double lat, double lon) {
    final zone = ((lon + 180) / 6).floor() + 1;
    final lonOrigin = (zone - 1) * 6 - 180 + 3;
    final latRad = _degToRad(lat);
    final lonRad = _degToRad(lon);
    final lonOriginRad = _degToRad(lonOrigin.toDouble());

    final e2 = _utmF * (2 - _utmF);
    final ep2 = e2 / (1 - e2);

    final sinLat = sin(latRad);
    final cosLat = cos(latRad);
    final tanLat = tan(latRad);

    final n = _utmA / sqrt(1 - e2 * sinLat * sinLat);
    final t = tanLat * tanLat;
    final c = ep2 * cosLat * cosLat;
    final a = cosLat * (lonRad - lonOriginRad);

    final m = _utmA *
        ((1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * latRad -
            (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) *
                sin(2 * latRad) +
            (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * sin(4 * latRad) -
            (35 * e2 * e2 * e2 / 3072) * sin(6 * latRad));

    final easting = _utmK0 *
            n *
            (a +
                (1 - t + c) * pow(a, 3) / 6 +
                (5 - 18 * t + t * t + 72 * c - 58 * ep2) * pow(a, 5) / 120) +
        500000.0;

    var northing = _utmK0 *
        (m +
            n *
                tanLat *
                (a * a / 2 +
                    (5 - t + 9 * c + 4 * c * c) * pow(a, 4) / 24 +
                    (61 - 58 * t + t * t + 600 * c - 330 * ep2) *
                        pow(a, 6) /
                        720));

    if (lat < 0) northing += 10000000.0;

    return (
      zone: zone,
      hemisphere: lat >= 0 ? 'N' : 'S',
      easting: easting,
      northing: northing,
    );
  }

  /// Formate une latitude ou longitude en degrés/minutes/secondes
  /// (ex: 51°20'57.9"N), format attendu par les liens Google Maps du type
  /// `google.com/maps/place/lat+lon`.
  static String toDms(double value, {required bool isLatitude}) {
    final letter = isLatitude
        ? (value >= 0 ? 'N' : 'S')
        : (value >= 0 ? 'E' : 'W');
    final abs = value.abs();
    final degrees = abs.floor();
    final minutesFull = (abs - degrees) * 60;
    final minutes = minutesFull.floor();
    final seconds = (minutesFull - minutes) * 60;
    return '$degrees°$minutes\'${seconds.toStringAsFixed(1)}"$letter';
  }
}
