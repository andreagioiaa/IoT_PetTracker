import 'package:pocketbase/pocketbase.dart';
import 'package:latlong2/latlong.dart';
import '../services/position_gps.dart';
import '../models/activities.dart';

class ActivitiesRepository {
  final PocketBase _pb;

  ActivitiesRepository(this._pb);

  // Prende l'attività attiva per un dato boardId, se esiste
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

  // Crea una nuova attività solo se non ne esiste già una attiva per lo stesso boardId
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

  // Termina l'attività attiva (es. alla fine di una camminata)
  Future<List<Activities>> fetchActivitiesByDate(
      String boardId, DateTime date) async {
    try {
      final startOfDay = DateTime(date.year, date.month, date.day, 0, 0, 0)
          .toUtc()
          .toIso8601String();
      final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

      final result = await _pb.collection('activities').getFullList(
            filter:
                'board_id = "$boardId" && start_time >= "$startOfDay" && start_time <= "$endOfDay"',
            sort: '-start_time',
          );

      return result.map((record) => Activities.fromRecord(record)).toList();
    } catch (e) {
      print('❌ Errore fetchActivitiesByDate: $e');
      return [];
    }
  }

  // Fetch dello storico completo delle attività per un dato boardId e giorno
  Future<List<dynamic>> fetchDailyStats(String boardId, DateTime date) async {
    try {
      // Definisci i limiti temporali del giorno scelto (00:00 - 23:59)
      final start =
          DateTime(date.year, date.month, date.day).toUtc().toIso8601String();
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

      final records = await _pb.collection('activities').getFullList(
            filter:
                'board_id = "$boardId" && start_time >= "$start" && start_time <= "$end"',
          );

      return records;
    } catch (e) {
      print("Errore fetch storico: $e");
      return [];
    }
  }

  /// Recupera l'ultimo stato dell'attività più recente per la board
  Future<String> getLatestActivityStatus(String boardId) async {
    try {
      // In getFirstListItem, il sort va inserito all'interno della mappa 'query'
      final record = await _pb.collection('activities').getFirstListItem(
            'board_id = "$boardId"',
            query: {
              'sort': '-created', // Ordina per data di creazione decrescente
            },
          );
      
      // Recuperiamo il valore del campo 'status'
      return record.getStringValue('status');
    } catch (e) {
      // Se la collezione è vuota o il record non esiste, 
      // restituiamo 'n' (normale) come fallback
      print("⚠️ [activities_repo]: Nessuna attività trovata o errore: $e");
      return 'n';
    }
  }

  /// Sottoscrizione Real-time per monitorare i cambi di stato dell'attività
  Future<void> subscribeToActivityUpdates(String boardId, Function(Map<String, dynamic>) onUpdate) async {
    try {
      // Ci iscriviamo ai cambiamenti della collezione filtrando per boardId
      await _pb.collection('activities').subscribe("*", (e) {
        if (e.record != null && e.record!.getStringValue('board_id') == boardId) {
          onUpdate(e.record!.toJson());
        }
      });
      print("📡 [activities_repo]: Sottoscrizione Real-time attività attiva");
    } catch (e) {
      print("🚨 [activities_repo]: Errore sottoscrizione: $e");
    }
  }

  /// Rimuove la sottoscrizione alle attività
  void unsubscribeFromActivities() {
    _pb.collection('activities').unsubscribe("*");
  }

  /// Filtra una lista di attività mantenendo solo quelle da mostrare ('s', 'w', 'i', 'v')
  List<Activities> filterValidActivities(List<Activities> attivitaGrezze) {
    final statusValidi = ['s', 'w', 'i', 'v'];
    return attivitaGrezze.where((act) {
      return statusValidi.contains(act.status.toLowerCase());
    }).toList();
  }

  /// Restituisce la stringa descrittiva dello stato dell'attività.
  /// Se lo stato è 'i' (Inside), calcola e restituisce direttamente il nome della zona (es. "Giardino").
  Future<String> getActivityLabel(Activities attivita) async {
    switch (attivita.status.toLowerCase()) {
      case 's':
        return 'Animale scappato';
      case 'w':
        return 'In passeggiata';
      case 'v':
        return 'In viaggio';
      case 'i':
        try {
          // Usa la chiave esterna per trovare la prima posizione di questa attività
          final result = await _pb.collection('positions').getFirstListItem(
                'activity = "${attivita.id}"',
              );
          
          final lat = result.getDoubleValue('lat');
          final lon = result.getDoubleValue('lon');
          
          // Calcola il nome della zona passando LatLng al servizio GPS
          String nomeZona = await PositionGpsService.calcolaZonaDalPunto(
            LatLng(lat, lon),
          );
          return nomeZona;
        } catch (e) {
          return 'Zona sicura sconosciuta';
        }
      default:
        return 'Sconosciuta';
    }
  }

}
