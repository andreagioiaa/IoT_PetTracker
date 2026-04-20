import 'package:pocketbase/pocketbase.dart';

/// Rappresenta i record della tabella "data_sent_raw", contenente i dati grezzi 
/// inviati dal dispositivo prima dell'elaborazione.
class DataSentRaw {
  final String id;
  final String boardId;
  final DateTime timestamp;
  final double lon;
  final double lat;
  final Map<String, dynamic> geo; // Campo JSON per dati geografici complessi
  final double battery;
  final int batteryPercent;
  final bool charging;
  final int steps;
  final bool sleep;
  final bool gpsValid;

  DataSentRaw({
    required this.id,
    required this.boardId,
    required this.timestamp,
    required this.lon,
    required this.lat,
    required this.geo,
    required this.battery,
    required this.batteryPercent,
    required this.charging,
    required this.steps,
    required this.sleep,
    required this.gpsValid,
  });

  /// Factory per mappare il record di PocketBase nell'oggetto Dart.
  factory DataSentRaw.fromRecord(RecordModel record) {
    return DataSentRaw(
      id: record.id,
      boardId: record.getStringValue('board_id'),
      timestamp: DateTime.parse(record.getStringValue('timestamp')).toLocal(),
      lon: record.getDoubleValue('lon'),
      lat: record.getDoubleValue('lat'),
      // Il campo 'geo' è di tipo JSON su PocketBase.
      geo: record.data['geo'] is Map ? record.data['geo'] as Map<String, dynamic> : {},
      battery: record.getDoubleValue('battery'),
      batteryPercent: record.getIntValue('battery_percent'),
      charging: record.getBoolValue('charging'),
      steps: record.getIntValue('steps'),
      sleep: record.getBoolValue('sleep'),
      gpsValid: record.getBoolValue('gps_valid'),
    );
  }

  /// Converte l'oggetto in mappa per eventuali log di sistema o update.
  Map<String, dynamic> toJson() {
    return {
      'board_id': boardId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'lon': lon,
      'lat': lat,
      'geo': geo,
      'battery': battery,
      'battery_percent': batteryPercent,
      'charging': charging,
      'steps': steps,
      'sleep': sleep,
      'gps_valid': gpsValid,
    };
  }
}