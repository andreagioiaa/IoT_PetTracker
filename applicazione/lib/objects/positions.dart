import 'package:pocketbase/pocketbase.dart';

/// Rappresenta un record della tabella "positions", utilizzato per il tracciamento
/// in tempo reale e lo storico dei movimenti.
class Positions {
  final String id;
  final DateTime timestamp;
  final double lon;
  final double lat;
  final Map<String, dynamic> geo; // Campo Geo/JSON
  final double battery;
  final int batteryPercent;
  final bool charging;
  final int feet; // Rappresenta i passi o la distanza calcolata
  final bool sleep;

  Positions({
    required this.id,
    required this.timestamp,
    required this.lon,
    required this.lat,
    required this.geo,
    required this.battery,
    required this.batteryPercent,
    required this.charging,
    required this.feet,
    required this.sleep,
  });

  /// Factory per convertire un RecordModel di PocketBase in un oggetto Positions.
  factory Positions.fromRecord(RecordModel record) {
    return Positions(
      id: record.id,
      // Parsing del timestamp con conversione al fuso orario locale.
      timestamp: DateTime.parse(record.getStringValue('timestamp')).toLocal(),
      lon: record.getDoubleValue('lon'),
      lat: record.getDoubleValue('lat'),
      // Gestione sicura del campo geo (mappa JSON).
      geo: record.data['geo'] is Map ? record.data['geo'] as Map<String, dynamic> : {},
      battery: record.getDoubleValue('battery'),
      batteryPercent: record.getIntValue('battery_percent'),
      charging: record.getBoolValue('charging'),
      feet: record.getIntValue('feet'),
      sleep: record.getBoolValue('sleep'),
    );
  }

  /// Converte l'oggetto in una mappa per operazioni di scrittura o log.
  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toUtc().toIso8601String(),
      'lon': lon,
      'lat': lat,
      'geo': geo,
      'battery': battery,
      'battery_percent': batteryPercent,
      'charging': charging,
      'feet': feet,
      'sleep': sleep,
    };
  }
}