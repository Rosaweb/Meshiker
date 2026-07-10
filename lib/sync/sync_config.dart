/// Réglages du moteur de synchronisation.
class SyncConfig {
  const SyncConfig({this.maxBatchSize = 200});

  /// Nombre maximal d'entités envoyées par appel RPC. Les lots plus
  /// grands sont découpés en plusieurs appels successifs. Pertinent au
  /// retour d'un trek de plusieurs jours en zone blanche, où des
  /// centaines de segments/POI peuvent s'être accumulés avant la
  /// première occasion de synchroniser (contrainte "100% déconnecté" du
  /// brief, section intro).
  final int maxBatchSize;
}
