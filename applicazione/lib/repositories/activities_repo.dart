import 'package:pocketbase/pocketbase.dart';
import '../objects/activities.dart';
import '../scambio.dart';

class ActivitiesRepository {
  final PocketBase _pb;

  ActivitiesRepository(this._pb);

  Future<Activities?> fetchCurrentActiveActivities(String boardId) async {
    try {
      final result = await _pb.collection('activities').getFirstListItem(
        'board_id = "$boardId" && is_active = true',
      );
      return Activities.fromRecord(result);
    } catch (e) {
      return null; // 404 gestito silenziosamente
    }
  }

  /// Rinominato in startNewActivity (singolare) per chiarezza
  Future<Activities?> startNewActivity(String boardId) async {
    try {
      // Analisi Critica: Prima di iniziare, controlla se ne esiste già una attiva
      final active = await fetchCurrentActiveActivities(boardId);
      if (active != null) return active;

      final record = await _pb.collection('activities').create(body: {
        'board_id': boardId,
        'start_time': DateTime.now().toUtc().toIso8601String(),
        'total_steps': 0,
        'is_active': true,
      });
      return Activities.fromRecord(record);
    } catch (e) {
      print('❌ Errore startNewActivity: $e');
      return null;
    }
  }


  /// Crea una nuova attività (es. all'inizio di una camminata)
  Future<Activities?> startActivities(String boardId) async {
    try {
      final record = await _pb.collection('activities').create(body: {
        'board_id': boardId,
        'start_time': DateTime.now().toUtc().toIso8601String(),
        'total_steps': 0,
        'is_active': true,
      });
      return Activities.fromRecord(record);
    } catch (e) {
      print('❌ Errore durante la creazione dell\'attività: $e');
      return null;
    }
  }


  Future<List<Activities>> fetchActivitiesByDate(String boardId, DateTime date) async {
    try {
      // Definiamo l'inizio e la fine del giorno in UTC per la query
      final startOfDay = DateTime(date.year, date.month, date.day, 0, 0, 0).toUtc().toIso8601String();
      final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59).toUtc().toIso8601String();

      final result = await _pb.collection('activities').getFullList(
        filter: 'board_id = "$boardId" && start_time >= "$startOfDay" && start_time <= "$endOfDay"',
        sort: '-start_time',
      );

      return result.map((record) => Activities.fromRecord(record)).toList();
    } catch (e) {
      print('❌ Errore fetchActivitiesByDate: $e');
      return [];
    }
  }

  Future<List<dynamic>> fetchDailyStats(String boardId, DateTime date) async {
    try {
      // Definisci i limiti temporali del giorno scelto (00:00 - 23:59)
      final start = DateTime(date.year, date.month, date.day).toUtc().toIso8601String();
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59).toUtc().toIso8601String();

      final records = await _pb.collection('activities').getFullList(
        filter: 'board_id = "$boardId" && start_time >= "$start" && start_time <= "$end"',
      );
      
      return records;
    } catch (e) {
      print("Errore fetch storico: $e");
      return [];
    }
  }
}