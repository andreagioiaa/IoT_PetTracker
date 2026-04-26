import '../services/authentication.dart';
import '../models/battery_data.dart';
import 'dart:async';

class BatteryRepository {
  // Trasferiamo qui lo StreamController per la batteria, ma tipizzato!
  static final StreamController<BatteryData> _batteryStreamController =
      StreamController<BatteryData>.broadcast();

  Stream<BatteryData> get batteryStream => _batteryStreamController.stream;

  /// Recupera l'ultimo record completo della batteria
  Future<BatteryData?> getLatestBattery() async {
    try {
      // Nota: Ho usato 'positions' perché nel tuo scambio.dart i dati sembrano essere lì.
      // Se invece usi la tabella specifica, cambia in 'battery_data'.
      final result = await pb.collection(tabella_batteryData).getList(
            page: 1,
            perPage: 1,
            sort: '-timestamp',
          );

      if (result.items.isEmpty) return null;
      return BatteryData.fromRecord(result.items.first);
    } catch (e) {
      print('🛑 [BatteryRepository] Errore getLatestBattery: $e');
      return null;
    }
  }

  /// Avvia l'ascolto in tempo reale e trasforma i RecordModel in BatteryData
  Future<void> subscribeToBatteryUpdates() async {
    try {
      pb.collection(tabella_batteryData).subscribe('*', (e) {
        if (e.record != null) {
          final data = BatteryData.fromRecord(e.record!);
          _batteryStreamController.add(data);
        }
      });
      print('✅ [BatteryRepository] Sottoscrizione Real-time attiva');
    } catch (e) {
      print('❌ [BatteryRepository] Errore sottoscrizione: $e');
    }
  }

  /// Metodo helper per sapere se è in carica (usando il modello)
  Future<bool> isCharging() async {
    final data = await getLatestBattery();
    return data?.charging ?? false;
  }
}
