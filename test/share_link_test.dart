import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/sharing/share_link.dart';

void main() {
  const token = 'AbCdEfGh_ijklMNop-qrSt'; // 22 caractères, alphabet base64 URL-safe

  group('shareTokenFromUri', () {
    test('accepte le lien canonique', () {
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/share/gpx/$token')), token);
    });

    test('accepte www (lien d\'un ancien QR après changement de domaine)', () {
      expect(shareTokenFromUri(Uri.parse('https://www.meshiker.com/share/gpx/$token')), token);
    });

    test('ignore la casse du domaine', () {
      expect(shareTokenFromUri(Uri.parse('https://MESHIKER.com/share/gpx/$token')), token);
    });

    test('refuse un autre domaine, http, ou un sous-domaine imitant', () {
      expect(shareTokenFromUri(Uri.parse('https://evil.com/share/gpx/$token')), isNull);
      expect(shareTokenFromUri(Uri.parse('http://meshiker.com/share/gpx/$token')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com.evil.com/share/gpx/$token')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://evilmeshiker.com/share/gpx/$token')), isNull);
    });

    test('refuse un chemin autre que /share/gpx/{token}', () {
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/share/gpx/$token/download')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/track/$token')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/share/gpx/')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/')), isNull);
    });

    test('refuse un token à la forme invalide', () {
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/share/gpx/court')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/share/gpx/${'a' * 65}')), isNull);
      expect(shareTokenFromUri(Uri.parse('https://meshiker.com/share/gpx/ab%2Fcd..ef!!gh')), isNull);
    });
  });

  test('le lien généré est reconnu par le récepteur', () {
    expect(shareTokenFromUri(Uri.parse('$kShareBaseUrl/$token')), token);
  });
}
