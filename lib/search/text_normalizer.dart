/// Normalisation de texte 100% locale (aucune dependance), pensee pour
/// le francais : suppression des accents/diacritiques, minuscules,
/// tokenisation simple par ponctuation.
class TextNormalizer {
  TextNormalizer._();

  // Table de correspondance caracteres accentues -> caracteres de base.
  // Volontairement limitee aux caracteres latins courants en francais (et,
  // dans une moindre mesure, en espagnol/italien/allemand, frequents sur
  // les noms de lieux alpins) plutot qu'une normalisation Unicode complete,
  // pour rester sans dependance externe (pas de package `unorm` ou
  // equivalent).
  static const Map<String, String> _diacriticsMap = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'ç': 'c',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
    'ñ': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
    'œ': 'oe', 'æ': 'ae',
  };

  /// Minuscules + accents supprimes.
  static String normalize(String input) {
    final lower = input.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_diacriticsMap[char] ?? char);
    }
    return buffer.toString();
  }

  /// Decoupe une chaine normalisee en tokens alphanumeriques (au moins 2
  /// caracteres), en ignorant la ponctuation et les tokens trop courts.
  static List<String> tokenize(String input) {
    final normalized = normalize(input);
    return normalized
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length >= 2)
        .toList();
  }
}
