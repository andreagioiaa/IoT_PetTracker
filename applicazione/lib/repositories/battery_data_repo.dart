import '../services/authentication.dart';
import '../models/battery_data.dart';
import 'dart:async';

class BatteryRepository {
  static final StreamController<BatteryData> _batteryStreamController =
      StreamController<BatteryData>.broadcast();

  Stream<BatteryData> get batteryStream => _batteryStreamController.stream;

  // Recupera l'ultimo record completo della batteria
  Future<BatteryData?> getLatestBattery(String boardId) async {
    try {
      final result = await pb.collection(tabella_batteryData).getList(
            page: 1,
            perPage: 1,
            sort: '-timestamp',
            filter: 'board_id = "$boardId"',
          );

      if (result.items.isEmpty) return null;
      return BatteryData.fromRecord(result.items.first);
    } catch (e) {
      print('🛑 [BatteryRepository] Errore getLatestBattery: $e');
      return null;
    }
  }

  // Avvia l'ascolto in tempo reale e trasforma i RecordModel in BatteryData
  Future<void> subscribeToBatteryUpdates(String boardId) async {
    try {
      pb.collection(tabella_batteryData).subscribe('*', (e) {
        if (e.record != null &&
            e.record!.getStringValue('board_id') == boardId) {
          final data = BatteryData.fromRecord(e.record!);
          _batteryStreamController.add(data);
        }
      });
      print('✅ [BatteryRepository] Sottoscrizione Real-time attiva');
    } catch (e) {
      print('❌ [BatteryRepository] Errore sottoscrizione: $e');
    }
  }

  // Metodo helper per sapere se è in carica
  Future<bool> isCharging(String boardId) async {
    final data = await getLatestBattery(boardId);
    return data?.charging ?? false;
  }
}
