import 'dart:async';
import 'package:pocketbase/pocketbase.dart';
import '../scambio.dart';
import '../objects/positions.dart';

class PositionsRepository {
  // 1. Controller per gestire lo stream di posizioni tipizzato
  final StreamController<Positions> _positionsController = StreamController<Positions>.broadcast();

  // Getter per lo stream, da usare nelle UI per sostituire 'scambio.posizioneStream'
  Stream<Positions> get positionsStream => _positionsController.stream;

  /// Sottoscrizione in tempo reale alla collezione delle posizioni
  void subscribeToPositions() {
    // Usiamo la costante definita in scambio.dart per coerenza
    pb.collection(tabella_positions).subscribe('*', (e) {
      if (e.record != null) {
        // Trasformiamo il RecordModel grezzo nel nostro oggetto Positions
        _positionsController.add(Positions.fromRecord(e.record!));
      }
    });
    print('📡 [PositionsRepository] Sottoscrizione Real-time attiva su $tabella_positions');
  }

  /// Recupera l'ultimo record della posizione registrato
  Future<Positions?> getLatestPosition() async {
    try {
      final result = await pb.collection(tabella_positions).getList(
        page: 1,
        perPage: 1,
        sort: '-timestamp',
      );
      
      if (result.items.isEmpty) return null;
      return Positions.fromRecord(result.items.first);
    } catch (e) {
      print('🛑 [PositionsRepository] Errore getLatestPosition: $e');
      return null;
    }
  }

  /// Recupera l'ultimo timestamp (sostituisce 'scambio.getUltimoTimestamp')
  Future<DateTime?> getLastTimestamp() async {
    try {
      final result = await pb.collection(tabella_positions).getList(
        page: 1,
        perPage: 1, 
        sort: '-timestamp'
      );

      if (result.items.isEmpty) return null;

      // Restituiamo il timestamp convertito al fuso orario locale
      String timeStr = result.items.first.getStringValue('timestamp');
      return DateTime.parse(timeStr).toLocal();
    } catch (e) {
      print('🛑 [PositionsRepository] Errore getLastTimestamp: $e');
      return null;
    }
  }

  /// Chiude lo stream quando non più necessario (per evitare memory leak)
  void dispose() {
    _positionsController.close();
  }
}