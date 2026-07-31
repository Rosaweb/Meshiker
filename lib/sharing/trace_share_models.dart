/// Résultat d'une demande de partage de trace : de quoi construire le
/// QR code et le lien affiché à l'utilisateur.
class TraceShareResult {
  const TraceShareResult({required this.token, required this.shareUrl});

  final String token;

  /// `https://meshiker.com/share/gpx/{token}` — c'est aussi exactement
  /// l'URL que le futur handler App Links devra résoudre (voir plan).
  final String shareUrl;
}

/// Erreur de partage destinée à être affichée telle quelle à
/// l'utilisateur (message déjà en français).
class TraceShareException implements Exception {
  const TraceShareException(this.message);

  final String message;

  @override
  String toString() => message;
}
