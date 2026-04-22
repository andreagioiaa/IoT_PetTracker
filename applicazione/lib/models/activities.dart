import 'package:pocketbase/pocketbase.dart';

/// Rappresenta un record della tabella "activities"
class Activities {
  final String id;
  final String boardId;
  final int totalSteps;
  final DateTime? startTime;
  final DateTime? endTime;
  final bool isActive;

  Activities({
    required this.id,
    required this.boardId,
    required this.totalSteps,
    this.startTime,
    this.endTime,
    required this.isActive,
  });

  /// Crea un'istanza di Activities a partire da un RecordModel di PocketBase.
  factory Activities.fromRecord(RecordModel record) {
    return Activities(
      id: record.id,
      boardId: record.getStringValue('board_id'),
      totalSteps: record.getIntValue('total_steps'),
      // Gestione dei campi data nullable per evitare crash se il campo è vuoto
      startTime: record.getStringValue('start_time').isNotEmpty
          ? DateTime.parse(record.getStringValue('start_time')).toLocal()
          : null,
      endTime: record.getStringValue('end_time').isNotEmpty
          ? DateTime.parse(record.getStringValue('end_time')).toLocal()
          : null,
      isActive: record.getBoolValue('is_active'),
    );
  }

  /// Converte l'oggetto in una mappa per l'invio al database.
  Map<String, dynamic> toJson() {
    return {
      'board_id': boardId,
      'total_steps': totalSteps,
      'start_time': startTime?.toUtc().toIso8601String(),
      'end_time': endTime?.toUtc().toIso8601String(),
      'is_active': isActive,
    };
  }
}