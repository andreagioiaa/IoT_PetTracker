import 'package:pocketbase/pocketbase.dart';

/// Rappresenta i record della tabella "positions_duplicate".
class PositionsDuplicate {
  final String id;
  final String boardId;
  final DateTime timestamp;
  final double lon;
  final double lat;
  final Map<String, dynamic> geo;
  final bool gpsValid;
  final int netFailCount;

  PositionsDuplicate({
    required this.id,
    required this.boardId,
    required this.timestamp,
    required this.lon,
    required this.lat,
    required this.geo,
    required this.gpsValid,
    required this.netFailCount,
  });

  /// Factory per mappare il record di PocketBase nell'oggetto Dart.
  factory PositionsDuplicate.fromRecord(RecordModel record) {
    return PositionsDuplicate(
      id: record.id,
      boardId: record.getStringValue('board_id'),
      // Parsing del timestamp obbligatorio per questa tabella.
      timestamp: DateTime.parse(record.getStringValue('timestamp')).toLocal(),
      lon: record.getDoubleValue('lon'),
      lat: record.getDoubleValue('lat'),
      // Gestione del campo JSON geo.
      geo: record.data['geo'] is Map ? record.data['geo'] as Map<String, dynamic> : {},
      gpsValid: record.getBoolValue('gps_valid'),
      netFailCount: record.getIntValue('net_fail_count'),
    );
  }

  /// Converte l'oggetto in mappa per eventuali reinvii o analisi.
  Map<String, dynamic> toJson() {
    return {
      'board_id': boardId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'lon': lon,
      'lat': lat,
      'geo': geo,
      'gps_valid': gpsValid,
      'net_fail_count': netFailCount,
    };
  }
}