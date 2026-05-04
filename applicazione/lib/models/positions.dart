import 'package:pocketbase/pocketbase.dart';

// Rappresenta un record della tabella "positions", utilizzato per il tracciamento in tempo reale e lo storico dei movimenti
class Positions {
  final String id;
  final String boardId;
  final DateTime timestamp;
  final double lon;
  final double lat;
  final String activityId;

  Positions({
    required this.id,
    required this.boardId,
    required this.timestamp,
    required this.lon,
    required this.lat,
    required this.activityId,
  });

  // Factory per convertire un RecordModel di PocketBase in un oggetto Positions
  factory Positions.fromRecord(RecordModel record) {
    return Positions(
      id: record.id,
      boardId: record.getStringValue('board_id'),
      // Parsing del timestamp con conversione al fuso orario locale.
      timestamp: DateTime.parse(record.getStringValue('timestamp')).toLocal(),
      lon: record.getDoubleValue('lon'),
      lat: record.getDoubleValue('lat'),
      activityId: record.getStringValue('activity'),
    );
  }

  /// Converte l'oggetto in una mappa per operazioni di scrittura o log
  Map<String, dynamic> toJson() {
    return {
      'board_id': boardId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'lon': lon,
      'lat': lat,
      'activity_id': activityId,
    };
  }
}
