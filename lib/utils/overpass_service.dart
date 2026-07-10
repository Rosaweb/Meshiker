import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class OsmPoi {
  final String id;
  final String name;
  final String type;
  final LatLng location;

  OsmPoi({required this.id, required this.name, required this.type, required this.location});
}

class OverpassService {
  static Future<List<OsmPoi>> fetchPois(double minLat, double minLon, double maxLat, double maxLon) async {
    final query = """
      [out:json][timeout:25];
      (
        node["amenity"~"drinking_water|hospital|shelter|fuel"]($minLat,$minLon,$maxLat,$maxLon);
        node["tourism"~"camp_site|alpine_hut"]($minLat,$minLon,$maxLat,$maxLon);
        node["shop"~"supermarket|bakery"]($minLat,$minLon,$maxLat,$maxLon);
      );
      out body;
    """;

    try {
      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        body: query,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final elements = data['elements'] as List;
        return elements.map((e) {
          final tags = e['tags'] ?? {};
          return OsmPoi(
            id: e['id'].toString(),
            name: tags['name'] ?? tags['amenity'] ?? tags['tourism'] ?? tags['shop'] ?? 'POI OSM',
            type: tags['amenity'] ?? tags['tourism'] ?? tags['shop'] ?? 'other',
            location: LatLng(e['lat'], e['lon']),
          );
        }).toList();
      }
    } catch (e) {
      print('Overpass error: $e');
    }
    return [];
  }
}
