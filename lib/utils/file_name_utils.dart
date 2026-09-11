import 'package:path/path.dart' as p;

/// Nettoie un texte saisi par l'utilisateur (typiquement un nom de trace)
/// pour qu'il soit utilisable comme *composant* de nom de fichier, sans
/// risque de traversée de répertoire quand ce nom sert à construire un
/// chemin sur le disque (`p.join(dossier, '$nomNettoye.gpx')`).
///
/// Retire tout séparateur de chemin (`/`, `\`) et caractère interdit par
/// Windows/Android, ainsi que toute séquence de `..` (qui n'a besoin
/// d'aucun séparateur pour être dangereuse une fois combinée à
/// `path.join`, qui la laisse traverser telle quelle). Un nom vide après
/// nettoyage retombe sur une valeur par défaut plutôt que de produire un
/// nom de fichier vide ou un chemin égal au dossier lui-même.
///
/// Utilisé par tout code qui dérive un nom de fichier d'un champ de
/// saisie libre (voir `TraceShareService`, `MapScreen` à l'arrêt d'un
/// enregistrement) — un seul endroit à corriger si la liste de
/// caractères interdits doit évoluer.
String sanitizeFileNameComponent(String name, {String fallback = 'trace'}) {
  final withoutSeparators = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final withoutTraversal = withoutSeparators.replaceAll(RegExp(r'\.{2,}'), '_');
  final trimmed = withoutTraversal.trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

/// Vrai si [path] est réellement contenu dans [root] une fois les deux
/// résolus (`canonicalize`, qui normalise `..`, `.` et les liens
/// symboliques). Utilisé en dernier rempart avant toute opération
/// destructive (suppression, déplacement) sur un chemin stocké en base
/// mais dérivé, à l'origine, d'un texte saisi par l'utilisateur.
///
/// Échoue fermé : si [root] est `null`/vide, ou si la résolution des
/// chemins échoue pour une raison quelconque, retourne `false` — mieux
/// vaut refuser l'opération que de risquer une sortie du dossier prévu.
bool isPathWithinRoot(String path, String? root) {
  if (root == null || root.isEmpty) return false;
  try {
    final normalizedRoot = p.canonicalize(root);
    final normalizedPath = p.canonicalize(path);
    return normalizedPath == normalizedRoot || p.isWithin(normalizedRoot, normalizedPath);
  } catch (_) {
    return false;
  }
}
