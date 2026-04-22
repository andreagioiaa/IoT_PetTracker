import 'package:pocketbase/pocketbase.dart';

/// Rappresenta un'area geografica definita (Geofence).
class Geofences {
  final String id;
  final String name;
  final double centerLon;
  final double centerLat;
  final bool isActive;
  final String userId;
  final String street;
  final int civic;
  final String city;
  final int cap;
  final dynamic vertices; // Può essere List<dynamic> o Map<String, dynamic>
  final DateTime created;
  final DateTime updated;

  Geofences({
    required this.id,
    required this.name,
    required this.centerLon,
    required this.centerLat,
    required this.isActive,
    required this.userId,
    required this.street,
    required this.civic,
    required this.city,
    required this.cap,
    required this.vertices,
    required this.created,
    required this.updated,
  });

  /// Factory per mappare il record di PocketBase nell'oggetto Dart.
  factory Geofences.fromRecord(RecordModel record) {
    return Geofences(
      id: record.id,
      name: record.getStringValue('name'),
      centerLon: record.getDoubleValue('center_lon'),
      centerLat: record.getDoubleValue('center_lat'),
      isActive: record.getBoolValue('is_active'),
      userId: record.getStringValue('user_id'),
      street: record.getStringValue('street'),
      civic: record.getIntValue('civic'),
      city: record.getStringValue('city'),
      cap: record.getIntValue('cap'),
      // Estrazione del campo JSON 'vertices'.
      vertices: record.data['vertices'],
      created: DateTime.parse(record.created).toLocal(),
      updated: DateTime.parse(record.updated).toLocal(),
    );
  }

  /// Converte l'oggetto in mappa per salvataggi o aggiornamenti.
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'center_lon': centerLon,
      'center_lat': centerLat,
      'is_active': isActive,
      'user_id': userId,
      'street': street,
      'civic': civic,
      'city': city,
      'cap': cap,
      'vertices': vertices,
    };
  }
}