import 'dart:async';
import 'package:pocketbase/pocketbase.dart';
import '../services/authentication.dart';
import '../models/positions.dart';
import 'package:latlong2/latlong.dart';

class PositionsRepository {
  final PocketBase _pb;
  final StreamController<Positions> _positionsController =
      StreamController<Positions>.broadcast();

  PositionsRepository(this._pb);

  Stream<Positions> get positionsStream => _positionsController.stream;

  // Sottoscrizione in tempo reale alla collezione 'positions'
  void subscribeToPositions() {
    _pb.collection(tabella_positions).subscribe('*', (e) {
      if (e.record != null) {
        _positionsController.add(Positions.fromRecord(e.record!));
      }
    });
  }

  // Recupera l'ultimo record della posizione registrato
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

  // Recupera l'ultimo timestamp in positions_repo.dart
  Future<DateTime?> getLastTimestamp() async {
    try {
      final result = await pb
          .collection(tabella_positions)
          .getList(page: 1, perPage: 1, sort: '-timestamp');

      if (result.items.isEmpty) return null;

      String timeStr = result.items.first.getStringValue('timestamp');

      // DateTime.parse riconosce automaticamente il formato ISO 8601 di PocketBase
      // Se la stringa termina con 'z', l'oggetto creato sarà già in UTC
      return DateTime.parse(timeStr).toUtc();
    } catch (e) {
      print('🛑 Errore durante il recupero del timestamp: $e');
      return null;
    }
  }

  // Chiude lo stream quando non più necessario (per evitare memory leak)
  void dispose() {
    _positionsController.close();
  }

  // Recupera tutte le posizioni di un giorno specifico
  Future<List<Positions>> fetchPositionsByDate(DateTime date) async {
    try {
      final start =
          DateTime(date.year, date.month, date.day).toUtc().toIso8601String();
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

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

  // Recupera TUTTE le posizioni legate a una specifica attività, ordinate per tempo
  Future<List<Positions>> fetchPositionsForActivity(String activityId) async {
    try {
      final result = await _pb.collection('positions').getFullList(
            filter: 'activity = "$activityId"',
            sort: 'timestamp',
          );
      return result.map((record) => Positions.fromRecord(record)).toList();
    } catch (e) {
      print('🛑 [PositionsRepository] Errore fetchPositionsForActivity: $e');
      return [];
    }
  }

  // Calcola la distanza totale in Km data una lista di posizioni
  static double calculateTotalDistance(List<dynamic> positions) {
    // Se ci sono meno di 2 posizioni, non si riesce a calcolare una distanza
    if (positions.length < 2) return 0.0;
    double meters = 0.0;
    const distanceCalc = Distance();

    // Itera su ogni coppia di posizioni consecutive
    for (int i = 0; i < positions.length - 1; i++) {
      double lat1 =
          double.tryParse(positions[i]['lat']?.toString() ?? '') ?? 0.0;
      double lon1 =
          double.tryParse(positions[i]['lon']?.toString() ?? '') ?? 0.0;
      double lat2 =
          double.tryParse(positions[i + 1]['lat']?.toString() ?? '') ?? 0.0;
      double lon2 =
          double.tryParse(positions[i + 1]['lon']?.toString() ?? '') ?? 0.0;

      // Calcola la distanza solo se entrambe le posizioni hanno latitudine valida
      if (lat1 != 0 && lat2 != 0) {
        meters += distanceCalc.distance(LatLng(lat1, lon1), LatLng(lat2, lon2));
      }
    }
    return meters / 1000; // Restituisce Km
  }
}
