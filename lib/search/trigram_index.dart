import 'text_normalizer.dart';

/// Index de trigrammes generique, pour une recherche floue (tolerante aux
/// fautes de frappe et aux variantes orthographiques) entierement locale.
///
/// Principe : chaque token est decoupe en trigrammes de caracteres
/// (fenetres glissantes de 3 caracteres, bordees par des marqueurs `#`),
/// et on indexe "trigramme -> ensemble de documents qui le contiennent".
/// A la recherche, on calcule une similarite de Jaccard entre les
/// trigrammes de la requete et ceux de chaque document candidat, ce qui
/// tolere les fautes de frappe et les variantes ("rando" ~ "randonnee")
/// sans reseau ni modele embarque.
///
/// Honnetete sur le terme "semantique" du brief : ceci est une recherche
/// floue LEXICALE (comparaison de caracteres), pas une recherche
/// semantique au sens IA/embeddings du terme. Une vraie similarite
/// semantique ("sentier familial" ~ "boucle facile pour enfants" sans mot
/// commun) demanderait des embeddings vectoriels, donc soit un modele
/// embarque lourd (cout batterie/stockage difficilement compatible avec
/// les contraintes du projet), soit un appel a une API cloud (incompatible
/// avec le mode 100% deconnecte). Le choix ici est un compromis assume :
/// robuste aux fautes de frappe et aux troncatures, sans les couts d'une
/// vraie approche semantique.
class TrigramIndex {
  final Map<String, Set<String>> _trigramToDocIds = {};
  final Map<String, Set<String>> _docTrigrams = {};
  final Map<String, List<String>> _docTokens = {};

  /// Indexe (ou re-indexe) un document identifie par [docId] a partir de
  /// son texte [text] (nom + description concatenes, typiquement).
  void indexDocument(String docId, String text) {
    removeDocument(docId);
    final tokens = TextNormalizer.tokenize(text);
    final trigrams = <String>{};
    for (final token in tokens) {
      trigrams.addAll(_trigramsOf(token));
    }
    _docTokens[docId] = tokens;
    _docTrigrams[docId] = trigrams;
    for (final tri in trigrams) {
      _trigramToDocIds.putIfAbsent(tri, () => {}).add(docId);
    }
  }

  void removeDocument(String docId) {
    final existing = _docTrigrams.remove(docId);
    _docTokens.remove(docId);
    if (existing == null) return;
    for (final tri in existing) {
      final docs = _trigramToDocIds[tri];
      docs?.remove(docId);
      if (docs != null && docs.isEmpty) _trigramToDocIds.remove(tri);
    }
  }

  void clear() {
    _trigramToDocIds.clear();
    _docTrigrams.clear();
    _docTokens.clear();
  }

  int get documentCount => _docTokens.length;

  /// Recherche floue : renvoie les documents tries par score decroissant
  /// (0 a ~1.3, un bonus etant applique en cas de correspondance exacte
  /// ou de prefixe).
  List<MapEntry<String, double>> search(String query, {int limit = 20}) {
    final queryTokens = TextNormalizer.tokenize(query);
    if (queryTokens.isEmpty) return [];

    // Etape 1 : ne considerer comme candidats que les documents qui
    // partagent au moins un trigramme avec la requete (evite un balayage
    // complet de tous les documents a chaque frappe).
    final candidateIds = <String>{};
    for (final token in queryTokens) {
      for (final tri in _trigramsOf(token)) {
        final docs = _trigramToDocIds[tri];
        if (docs != null) candidateIds.addAll(docs);
      }
    }

    final scored = <MapEntry<String, double>>[];
    for (final docId in candidateIds) {
      final score = _scoreDocument(queryTokens, docId);
      if (score > 0) scored.add(MapEntry(docId, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).toList();
  }

  double _scoreDocument(List<String> queryTokens, String docId) {
    final docTokens = _docTokens[docId] ?? const [];
    if (docTokens.isEmpty) return 0;

    double total = 0;
    for (final qToken in queryTokens) {
      double best = 0;
      final qTrigrams = _trigramsOf(qToken);
      for (final dToken in docTokens) {
        if (dToken == qToken) {
          best = 1.3; // correspondance exacte : bonus
          break;
        }
        if (dToken.startsWith(qToken) || qToken.startsWith(dToken)) {
          best = best < 1.1 ? 1.1 : best; // prefixe : leger bonus
        }
        final dTrigrams = _trigramsOf(dToken);
        final sim = _jaccard(qTrigrams, dTrigrams);
        if (sim > best) best = sim;
      }
      total += best;
    }
    return total / queryTokens.length;
  }

  double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final intersection = a.intersection(b).length;
    final union = a.union(b).length;
    return union == 0 ? 0 : intersection / union;
  }

  /// Trigrammes d'un token, bordes par `#` pour distinguer debut/fin de
  /// mot (ex: "mont" -> "##m", "#mo", "mon", "ont", "nt#", "t##").
  Set<String> _trigramsOf(String token) {
    final padded = '##$token##';
    final result = <String>{};
    for (var i = 0; i <= padded.length - 3; i++) {
      result.add(padded.substring(i, i + 3));
    }
    return result;
  }
}
