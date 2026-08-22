import 'package:flutter/material.dart';

/// Taxonomie fixe des types de POI OSM proposés à l'import, indépendante
/// des `WaypointCategory` personnelles de l'utilisateur (voir
/// `IsarService.resolveOrCreateCategoryForOsmType` pour la concordance
/// entre les deux).
class OsmPoiCategoryDef {
  final String id;
  final String label;
  final List<String> overpassFilters; // fragments Overpass, ex: '["shop"="bakery"]'
  final IconData icon; // icône du marqueur carte (POI non sauvegardé)
  final Color color;
  final String waypointIconName; // iconName une fois converti en WaypointCategory

  const OsmPoiCategoryDef({
    required this.id,
    required this.label,
    required this.overpassFilters,
    required this.icon,
    required this.color,
    required this.waypointIconName,
  });
}

const kOsmPoiCategories = [
  OsmPoiCategoryDef(id: 'water', label: "Point d'eau",
      overpassFilters: ['["amenity"="drinking_water"]'],
      icon: Icons.water_drop, color: Colors.blue, waypointIconName: 'water_drop'),
  OsmPoiCategoryDef(id: 'camping', label: 'Camping',
      overpassFilters: ['["tourism"="camp_site"]'],
      icon: Icons.holiday_village, color: Colors.green, waypointIconName: 'camping'),
  OsmPoiCategoryDef(id: 'hut', label: 'Cabane/refuge',
      overpassFilters: ['["tourism"="alpine_hut"]', '["tourism"="wilderness_hut"]'],
      icon: Icons.home, color: Colors.brown, waypointIconName: 'home'),
  OsmPoiCategoryDef(id: 'hotel', label: 'Hôtel/auberge',
      overpassFilters: ['["tourism"="hotel"]', '["tourism"="guest_house"]', '["tourism"="hostel"]'],
      icon: Icons.hotel, color: Colors.indigo, waypointIconName: 'hotel'),
  OsmPoiCategoryDef(id: 'restaurant', label: 'Restaurant',
      overpassFilters: ['["amenity"="restaurant"]'],
      icon: Icons.restaurant, color: Colors.deepOrange, waypointIconName: 'restaurant'),
  OsmPoiCategoryDef(id: 'grocery', label: 'Supermarché/épicerie',
      overpassFilters: ['["shop"="supermarket"]', '["shop"="convenience"]'],
      icon: Icons.local_grocery_store, color: Colors.orange, waypointIconName: 'grocery'),
  OsmPoiCategoryDef(id: 'bakery', label: 'Boulangerie',
      overpassFilters: ['["shop"="bakery"]'],
      icon: Icons.bakery_dining, color: Colors.amber, waypointIconName: 'bakery'),
  OsmPoiCategoryDef(id: 'snack', label: 'Snack',
      overpassFilters: ['["amenity"="fast_food"]', '["amenity"="cafe"]'],
      icon: Icons.fastfood, color: Colors.deepOrangeAccent, waypointIconName: 'snack'),
  OsmPoiCategoryDef(id: 'train_station', label: 'Gare',
      overpassFilters: ['["railway"="station"]', '["railway"="halt"]'],
      icon: Icons.train, color: Colors.blueGrey, waypointIconName: 'train'),
  OsmPoiCategoryDef(id: 'hospital', label: 'Hôpital',
      overpassFilters: ['["amenity"="hospital"]'],
      icon: Icons.local_hospital, color: Colors.red, waypointIconName: 'hospital'),
  OsmPoiCategoryDef(id: 'police', label: 'Gendarmerie/police',
      overpassFilters: ['["amenity"="police"]'],
      icon: Icons.local_police, color: Colors.blueAccent, waypointIconName: 'police'),
  OsmPoiCategoryDef(id: 'tourist_office', label: 'Office de tourisme',
      overpassFilters: ['["tourism"="information"]'],
      icon: Icons.info, color: Colors.teal, waypointIconName: 'info'),
];
