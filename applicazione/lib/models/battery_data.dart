import 'package:pocketbase/pocketbase.dart';

/// Rappresenta i dati della telemetria batteria dalla tabella "battery_data".
class BatteryData {
  final String id;
  final String boardId;
  final DateTime timestamp;
  final double battery; // Solitamente espresso in volt (es. 4.2)
  final int batteryPercent; // Livello percentuale (0-100)
  final bool charging; // Stato di ricarica

  BatteryData({
    required this.id,
    required this.boardId,
    required this.timestamp,
    required this.battery,
    required this.batteryPercent,
    required this.charging,
  });

  /// Factory per convertire un RecordModel grezzo in un oggetto tipizzato.
  factory BatteryData.fromRecord(RecordModel record) {
    return BatteryData(
      id: record.id,
      boardId: record.getStringValue('board_id'),
      // Parsing della data con conversione al fuso locale.
      timestamp: DateTime.parse(record.getStringValue('timestamp')).toLocal(),
      battery: record.getDoubleValue('battery'),
      batteryPercent: record.getIntValue('battery_percent'),
      charging: record.getBoolValue('charging'),
    );
  }

  /// Converte l'oggetto in JSON per eventuali operazioni di scrittura.
  Map<String, dynamic> toJson() {
    return {
      'board_id': boardId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'battery': battery,
      'battery_percent': batteryPercent,
      'charging': charging,
    };
  }
}
