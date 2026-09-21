/// Liens de partage GPX (`https://meshiker.com/share/gpx/{token}`) : format,
/// domaine et extraction du token, en un seul endroit.
///
/// Changer de domaine canonique (ex. passer à `www.meshiker.com`) suppose de
/// modifier ENSEMBLE :
/// 1. [kShareHost] ici (liens générés et QR codes) ;
/// 2. `android:host` de l'intent-filter `autoVerify` dans
///    `android/app/src/main/AndroidManifest.xml` ;
/// 3. le domaine principal dans Vercel (le domaine déclaré ne doit PAS
///    rediriger : Android refuse de valider `assetlinks.json` derrière une
///    redirection) et `public/.well-known/assetlinks.json` (dépôt
///    Meshiker_web) ;
/// 4. `TRACK_URL_BASE` de l'Edge Function `send-location-share-email` et
///    `_shareUrlBase` de `location_share_active_screen.dart`.
/// Les liens déjà distribués (QR imprimés/partagés) restent valables tant que
/// l'ancien domaine renvoie vers le nouveau : [kShareHostAliases] les
/// reconnaît à la saisie/au scan, sans exiger la vérification App Links.
library;

/// Domaine canonique des liens générés par l'app.
const kShareHost = 'meshiker.com';

/// Domaines reconnus comme des liens de partage Meshiker (et non comme une
/// URL directe vers un serveur local, cf. `TraceShareService.importFromShare`).
const kShareHostAliases = {'meshiker.com', 'www.meshiker.com'};

/// Préfixe des liens de partage GPX générés par l'app.
const kShareBaseUrl = 'https://$kShareHost/share/gpx';

/// Forme d'un token généré par la RPC `create_trace_share` (16 octets
/// aléatoires en base64 URL-safe sans padding, ~22 caractères). Sert à valider
/// tout texte collé, scanné ou reçu par lien avant de le placer dans une URL.
final kShareTokenPattern = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

bool isShareHost(String host) => kShareHostAliases.contains(host.toLowerCase());

/// Token d'un lien de partage GPX reçu (App Link), ou `null` si [uri] n'est
/// pas exactement `https://<domaine Meshiker>/share/gpx/{token}`. Strict à
/// dessein : un lien arrive d'une source non fiable (navigateur, message).
String? shareTokenFromUri(Uri uri) {
  if (uri.scheme != 'https' || !isShareHost(uri.host)) return null;

  final segments = uri.pathSegments;
  if (segments.length != 3 || segments[0] != 'share' || segments[1] != 'gpx') {
    return null;
  }
  final token = segments[2];
  return kShareTokenPattern.hasMatch(token) ? token : null;
}
