import 'package:isar_community/isar.dart';

part 'trace_segment_entry.g.dart';

/// Référence ordonnée d'un [Segment] au sein d'une [Trace].
///
/// C'est cette classe — et uniquement elle — qui porte la notion d'ordre
/// et de sens de parcours. Elle permet à un même segment physique
/// d'appartenir à la "toile d'araignée" partagée (potentiellement
/// emprunté par des dizaines de traces différentes) tout en étant
/// parcouru dans un ordre et une direction propres à chaque trace.
///
/// Exemple concret : deux randonneurs empruntent le même segment de crête,
/// l'un en montée (nord → sud), l'autre en descente (sud → nord). Le
/// [Segment] est unique et partagé ; seul `traveledForward` diffère entre
/// leurs deux [TraceSegmentEntry] respectifs.
@embedded
class TraceSegmentEntry {
  TraceSegmentEntry();

  TraceSegmentEntry.create({
    required this.segmentUuid,
    required this.orderIndex,
    this.traveledForward = true,
    this.enteredAt,
    this.exitedAt,
  });

  /// UUID stable (local ou serveur) du [Segment] référencé — jamais l'id
  /// interne Isar, qui n'a de sens que sur l'appareil qui l'a créé.
  String segmentUuid = '';

  /// Position du segment dans l'itinéraire (0, 1, 2, ...).
  int orderIndex = 0;

  /// `true` si la trace parcourt le segment de son premier point vers son
  /// dernier point (tel qu'enregistré à l'origine) ; `false` si elle le
  /// parcourt en sens inverse.
  bool traveledForward = true;

  /// Horodatages réels d'entrée/sortie sur ce segment POUR CETTE trace.
  /// À distinguer des métadonnées globales du segment (passageCount,
  /// lastPassageAt...), qui agrègent tous les passages de tous les
  /// utilisateurs.
  DateTime? enteredAt;
  DateTime? exitedAt;
}
