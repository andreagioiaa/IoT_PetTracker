import 'package:flutter/material.dart';
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

  /// Recupera l'ultimo oggetto Activities completo per la board
  Future<Activities?> getLastActivity(String boardId) async {
    try {
      // 1. Usiamo getList: qui 'sort', 'page' e 'perPage' sono parametri definiti.
      // 2. Ordiniamo per '-start_time' per avere la più recente (visto nello screenshot).
      final result = await _pb.collection('activities').getList(
            page: 1,
            perPage: 1,
            filter: 'board_id = "$boardId"',
            sort: '-start_time', 
          );
      
      // 3. Verifichiamo se la lista contiene almeno un elemento
      if (result.items.isNotEmpty) {
        return Activities.fromRecord(result.items.first);
      }
      
      print("⚠️ [activities_repo]: Nessuna attività trovata per board $boardId.");
      return null;
    } catch (e) {
      print("🚨 [activities_repo]: Errore critico in getLastActivity: $e");
      return null;
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
    print("[activities_repo]: tento di prendere l'ActivityLabel dell'ultima attività");
    switch (attivita.status.toLowerCase()) {
      case 's':
        return 'Animale scappato';
      case 'w':
        return 'In passeggiata';
      case 'v':
        return 'In viaggio';
      case 'a':
        return "Sleep: in viaggio";
      case 'z':
        return "Sleep: in camminata";
      case 'd':
        return "Sleep: a casa";
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


  /*
  /// Recupera l'etichetta di stato dell'attività più recente.
  /// Combina il recupero dell'attività e la decodifica della sua zona/etichetta.
  Future<String> getActivityStatus(String boardId) async {
    try {
      // 1. Recuperiamo l'ultima attività in modo asincrono.
      // Usiamo 'this.' in modo esplicito (opzionale ma chiaro) per chiamare un metodo della stessa classe.
      final Activities? ultimaAttivita = await this.getLastActivity(boardId);

      // 2. Barriera di sicurezza (Null Safety): se l'attività non esiste o c'è stato un errore
      if (ultimaAttivita == null) {
        print("⚠️ [activities_repo]: Nessuna attività trovata per la board $boardId.");
        return 'Nessuna attività'; // Fallback da mostrare nella UI
      }

      // 3. Se arriviamo qui, 'ultimaAttivita' esiste ed è un oggetto concreto.
      // Passiamo l'oggetto a getActivityLabel e attendiamo la decodifica (che potrebbe richiedere il GPS).
      final String etichetta = await this.getActivityLabel(ultimaAttivita);
      
      return etichetta;
      
    } catch (e) {
      // Gestione di eventuali eccezioni non previste durante il flusso
      print("🚨 [activities_repo]: Errore critico in getActivityStatus: $e");
      return 'Stato sconosciuto'; // Fallback per la UI in caso di errore di sistema
    }
  }*/

  /*
  /// Recupera l'etichetta testuale (es. "In viaggio", "Giardino") dell'ultima attività
  Future<String> getActivityStatus(String boardId) async {
    try {
      // Richiamiamo la funzione che abbiamo appena corretto
      final Activities? ultimaAttivita = await getLastActivity(boardId);

      if (ultimaAttivita == null) {
        return 'Nessuna attività';
      }

      // Passiamo l'oggetto reale a getActivityLabel per la decodifica
      return await getActivityLabel(ultimaAttivita);
    } catch (e) {
      print("🚨 [activities_repo]: Errore in getActivityStatus: $e");
      return 'Stato sconosciuto';
    }
  }*/

  /// Recupera l'etichetta testuale e la configurazione UI (titolo, colore, icona)
  Future<Map<String, dynamic>> getActivityStatus(String boardId) async {
    try {
      final Activities? ultimaAttivita = await getLastActivity(boardId);

      if (ultimaAttivita == null) {
        return {
          'titolo': 'Nessuna attività',
          'colore': Colors.grey,
          'icona': Icons.help_outline
        };
      }

      // Passiamo l'oggetto reale a getActivityLabel per la decodifica del titolo
      String titoloAttivita = await getActivityLabel(ultimaAttivita);
      
      // Ritorniamo la mappa completa passando l'attività e il titolo ricavato
      return getConfigForActivity(ultimaAttivita, titoloAttivita);
    } catch (e) {
      print("🚨 [activities_repo]: Errore in getActivityStatus: $e");
      return {
        'titolo': 'Stato sconosciuto',
        'colore': Colors.grey,
        'icona': Icons.error_outline
      };
    }
  }
  

  // Restituisce titolo, colore e icona in base allo stato dell'attività
  Map<String, dynamic> getConfigForActivity(Activities attivita, String titolo) {
    switch (attivita.status.toLowerCase()) {
      case 's':
        return {'titolo': titolo, 'colore': Colors.red, 'icona': Icons.warning_amber_rounded};
      case 'w':
        return {'titolo': titolo, 'colore': const Color(0xFF00C6B8), 'icona': Icons.directions_walk};
      case 'z':
        return {'titolo': titolo, 'colore': const Color(0xFF00C6B8), 'icona': Icons.directions_walk};
      case 'i':
        return {'titolo': titolo, 'colore': Colors.green, 'icona': Icons.home_rounded};
      case 'z':
        return {'titolo': titolo, 'colore': Colors.green, 'icona': Icons.home_rounded};
      case 'v':
        return {'titolo': titolo, 'colore': Colors.blue, 'icona': Icons.directions_car};
      case 'a':
        return {'titolo': titolo, 'colore': Colors.blue, 'icona': Icons.directions_car};
      default:
        return {'titolo': titolo, 'colore': Colors.grey, 'icona': Icons.help_outline};
    }
  }

  // Restituisce titolo, colore e icona in base allo stato dell'attività
  Map<String, dynamic> getConfigForActivityDR(Activities attivita, String titolo) {
    switch (attivita.status.toLowerCase()) {
      case 's' || 'p':
        return {'titolo': titolo, 'colore': Colors.red, 'icona': Icons.warning_amber_rounded};
      case 'w' || 'z':
        return {'titolo': titolo, 'colore': const Color(0xFF00C6B8), 'icona': Icons.directions_walk};
      case 'i' || 'd':
        return {'titolo': titolo, 'colore': Colors.green, 'icona': Icons.home_rounded};
      case 'v' || 'a':
        return {'titolo': titolo, 'colore': Colors.blue, 'icona': Icons.directions_car};
      default:
        return {'titolo': titolo, 'colore': Colors.grey, 'icona': Icons.help_outline};
    }
  }

  Future<String> getLatestActivityStatus(String boardId) async {
    try {
      final result = await _pb.collection('activities').getList(
            page: 1,
            perPage: 1,
            filter: 'board_id = "$boardId"',
            sort: '-start_time',
          );
      
      if (result.items.isNotEmpty) {
        return result.items.first.getStringValue('status');
      }
      return 'n'; 
    } catch (e) {
      return 'n';
    }
  }
}