import 'dart:async';
import 'package:pocketbase/pocketbase.dart';
import '../scambio.dart';
import '../objects/positions.dart';

class PositionsRepository {
  final PocketBase _pb; // 1. Devi dichiarare questa variabile privata
  final StreamController<Positions> _positionsController =
      StreamController<Positions>.broadcast();

  // 2. IL PUNTO CRITICO: Devi aggiungere questo costruttore
  PositionsRepository(this._pb);

  Stream<Positions> get positionsStream => _positionsController.stream;

  void subscribeToPositions() {
    // Nota: ora usiamo _pb (quella passata al costruttore)
    _pb.collection(tabella_positions).subscribe('*', (e) {
      if (e.record != null) {
        _positionsController.add(Positions.fromRecord(e.record!));
      }
    });
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
      final result = await pb
          .collection(tabella_positions)
          .getList(page: 1, perPage: 1, sort: '-timestamp');

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

  Future<List<Positions>> fetchPositionsByDate(DateTime date) async {
    try {
      // Definiamo i limiti del giorno (00:00 - 23:59) in UTC
      final start =
          DateTime(date.year, date.month, date.day).toUtc().toIso8601String();
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

      // Query alla collezione 'positions'
      final result = await _pb.collection('positions').getFullList(
            filter: 'timestamp >= "$start" && timestamp <= "$end"',
            sort: 'timestamp',
          );

      return result.map((record) => Positions.fromRecord(record)).toList();
    } catch (e) {
      print('🛑 [PositionsRepository] Errore fetchPositionsByDate: $e');
      return [];
    }
  }
}
