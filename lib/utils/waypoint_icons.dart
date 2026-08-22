import 'package:flutter/material.dart';

/// Mapping icône centralisé pour les types de waypoints (`WaypointCategory.iconName`).
/// Utilisé à la fois par l'écran de gestion des types, le formulaire d'édition
/// de waypoint et le rendu carte (`_WaypointsLayer`) -- les garder synchronisés
/// passe par ce point unique plutôt que par des switchs dupliqués.
IconData iconForWaypointCategory(String name) {
  switch (name) {
    case 'water_drop': return Icons.water_drop;
    case 'home': return Icons.home;
    case 'tent': return Icons.holiday_village;
    case 'terrain': return Icons.terrain;
    case 'landscape': return Icons.landscape;
    case 'camera': return Icons.camera_alt;
    case 'warning': return Icons.warning;
    case 'info': return Icons.info;
    // Ajoutés pour les catégories créées automatiquement depuis un POI OSM.
    case 'camping': return Icons.holiday_village;
    case 'hotel': return Icons.hotel;
    case 'restaurant': return Icons.restaurant;
    case 'grocery': return Icons.local_grocery_store;
    case 'bakery': return Icons.bakery_dining;
    case 'snack': return Icons.fastfood;
    case 'train': return Icons.train;
    case 'hospital': return Icons.local_hospital;
    case 'police': return Icons.local_police;
    default: return Icons.location_on;
  }
}
