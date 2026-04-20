import 'package:pocketbase/pocketbase.dart';
import '../objects/activities.dart';
import '../scambio.dart';

class ActivitiesRepository {
  final PocketBase _pb;

  // Passiamo l'istanza di PocketBase nel costruttore per favorire il disaccoppiamento
  ActivitiesRepository(this._pb);

  /// Recupera l'attività attualmente attiva per una specifica board
  Future<Activities?> fetchCurrentActiveActivities(String boardId) async {
    try {
      final result = await _pb.collection('activities').getFirstListItem(
        'board_id = "$boardId" && is_active = true',
      );
      return Activities.fromRecord(result);
    } catch (e) {
      // Se non trova record, PocketBase lancia un errore 404
      print('ℹ️ Nessuna attività attiva trovata per la board $boardId');
      return null;
    }
  }

  /// Recupera la lista di tutte le attività passate
  Future<List<Activities>> fetchActivitiesHistory({int limit = 50}) async {
    try {
      final result = await _pb.collection('activities').getList(
        page: 1,
        perPage: limit,
        sort: '-start_time',
      );
      
      return result.items.map((record) => Activities.fromRecord(record)).toList();
    } catch (e) {
      print('❌ Errore nel recupero dello storico attività: $e');
      return [];
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