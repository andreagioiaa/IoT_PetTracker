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
}