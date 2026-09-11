import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/utils/file_name_utils.dart';
import 'package:path/path.dart' as p;

void main() {
  group('sanitizeFileNameComponent', () {
    test('laisse un nom normal inchangé (à part le trim)', () {
      expect(sanitizeFileNameComponent('Mont Blanc 2024'), 'Mont Blanc 2024');
    });

    test('remplace les séparateurs de chemin', () {
      expect(sanitizeFileNameComponent('a/b\\c'), 'a_b_c');
    });

    test('neutralise une tentative de traversée de répertoire', () {
      final cleaned = sanitizeFileNameComponent('../../etc/passwd');
      expect(cleaned.contains('..'), isFalse);
      expect(cleaned.contains('/'), isFalse);
    });

    test('".." seul devient un underscore, jamais un chemin de traversée', () {
      expect(sanitizeFileNameComponent('..'), '_');
    });

    test('retombe sur la valeur par défaut pour une entrée vide ou blanche', () {
      expect(sanitizeFileNameComponent(''), 'trace');
      expect(sanitizeFileNameComponent('   '), 'trace');
    });
  });

  group('isPathWithinRoot', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('meshiker_security_test_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('accepte un chemin réellement sous le dossier racine', () {
      final inside = p.join(root.path, 'trace.gpx');
      expect(isPathWithinRoot(inside, root.path), isTrue);
    });

    test('refuse un chemin qui sort du dossier racine via ..', () {
      final outside = p.join(root.path, '..', 'ailleurs.gpx');
      expect(isPathWithinRoot(outside, root.path), isFalse);
    });

    test('refuse quand root est null ou vide', () {
      expect(isPathWithinRoot(p.join(root.path, 'x.gpx'), null), isFalse);
      expect(isPathWithinRoot(p.join(root.path, 'x.gpx'), ''), isFalse);
    });
  });
}
