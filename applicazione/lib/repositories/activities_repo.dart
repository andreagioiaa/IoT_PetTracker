import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:latlong2/latlong.dart';
import '../services/position_gps.dart';
import '../models/activities.dart';
import '../models/statistics.dart';
import 'positions_repo.dart';

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

  // Crea una nuova attività (es. all'inizio di una camminata)
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

      print(
          "⚠️ [activities_repo]: Nessuna attività trovata per board $boardId.");
      return null;
    } catch (e) {
      print("🚨 [activities_repo]: Errore critico in getLastActivity: $e");
      return null;
    }
  }

  // Sottoscrizione Real-time per monitorare i cambi di stato dell'attività
  Future<void> subscribeToActivityUpdates(
      String boardId, Function(Map<String, dynamic>) onUpdate) async {
    try {
      // Ci iscriviamo ai cambiamenti della collezione filtrando per boardId
      await _pb.collection('activities').subscribe("*", (e) {
        if (e.record != null &&
            e.record!.getStringValue('board_id') == boardId) {
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

  // Filtra le attività restituite mantenendo solo quelle con status valido
  List<Activities> filterValidActivities(List<Activities> attivitaGrezze) {
    final statusValidi = ['s', 'w', 'i', 'v', 'p', 'z', 'd', 'a'];
    return attivitaGrezze.where((act) {
      return statusValidi.contains(act.status.toLowerCase());
    }).toList();
  }

  // Restituisce la stringa descrittiva dello stato dell'attività
  // Se isDailyRecap è true, associa i deep sleep ai corrispettivi attivi
  // Se lo stato è 'i' (Inside), calcola e restituisce direttamente il nome della zona (es. "Giardino")
  Future<String> getActivityLabel(Activities attivita,
      {bool isDailyRecap = false}) async {
    String stato = attivita.status.toLowerCase();

    // Se siamo nel Daily Recap, "mascheriamo" lo stato trasformandolo nel suo equivalente attivo
    if (isDailyRecap) {
      if (stato == 'p') stato = 's';
      if (stato == 'z') stato = 'w';
      if (stato == 'd') stato = 'i';
      if (stato == 'a') stato = 'v';
    }

    switch (stato) {
      case 's':
        return 'Animale scappato';
      case 'w':
        return 'In passeggiata';
      case 'v':
        return 'In viaggio';
      // Questi casi verranno letti SOLO dalla Home
      case 'a':
        return "Sleep: in viaggio";
      case 'z':
        return "Sleep: in camminata";
      case 'd':
        return "Sleep: a casa";
      case 'i':
        try {
          final result = await _pb.collection('positions').getFirstListItem(
                'activity = "${attivita.id}"',
              );
          final lat = result.getDoubleValue('lat');
          final lon = result.getDoubleValue('lon');

          return await PositionGpsService.calcolaZonaDalPunto(LatLng(lat, lon));
        } catch (e) {
          return 'Zona sicura sconosciuta';
        }
      default:
        return 'Sconosciuta';
    }
  }

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
  Map<String, dynamic> getConfigForActivity(
      Activities attivita, String titolo) {
    switch (attivita.status.toLowerCase()) {
      case 's':
        return {
          'titolo': titolo,
          'colore': Colors.red,
          'icona': Icons.warning_amber_rounded
        };
      case 'w':
        return {
          'titolo': titolo,
          'colore': const Color(0xFF00C6B8),
          'icona': Icons.directions_walk
        };
      case 'z':
        return {
          'titolo': titolo,
          'colore': const Color(0xFF00C6B8),
          'icona': Icons.directions_walk
        };
      case 'i':
        return {
          'titolo': titolo,
          'colore': Colors.green,
          'icona': Icons.home_rounded
        };
      case 'v':
        return {
          'titolo': titolo,
          'colore': Colors.blue,
          'icona': Icons.directions_car
        };
      case 'a':
        return {
          'titolo': titolo,
          'colore': Colors.blue,
          'icona': Icons.directions_car
        };
      default:
        return {
          'titolo': titolo,
          'colore': Colors.grey,
          'icona': Icons.help_outline
        };
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

  // Recupera le statistiche giornaliere (durata totale, distanza, passi) per un dato boardId e giorno, con possibilità di filtrare per status
  Future<DailyStats> getDailyStatistics(String boardId, DateTime date) async {
    try {
      // Impostiamo i limiti di tempo della giornata (da 00:00 a 23:59) in UTC
      final start =
          DateTime(date.year, date.month, date.day).toUtc().toIso8601String();
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

      // Scarichiamo TUTTE le attività di questa board per il giorno selezionato
      final records = await _pb.collection('activities').getFullList(
            filter:
                'board_id = "$boardId" && start_time >= "$start" && start_time <= "$end"',
          );

      int totalSteps = 0;
      int totalMinutes = 0;

      // Cikliamo ogni attività del giorno per sommare Passi e Minuti
      for (var record in records) {
        // Somma i passi (assicurati che il campo nel DB si chiami 'total_steps' o modificalo)
        totalSteps += record.getIntValue('total_steps');

        // Calcola il tempo: differenza tra fine e inizio
        String startStr = record.getStringValue('start_time');
        String endStr = record.getStringValue('end_time');

        if (startStr.isNotEmpty) {
          DateTime startTime = DateTime.parse(startStr);
          // Se non c'è un orario di fine, significa che è in corso, usiamo "Adesso"
          DateTime endTime = endStr.isNotEmpty
              ? DateTime.parse(endStr)
              : DateTime.now().toUtc();

          totalMinutes += endTime.difference(startTime).inMinutes;
        }
      }

      // Calcolo dei Km totali sfruttando il PositionsRepository che hai già!
      // Usiamo una nuova istanza per comodità
      final posRepo = PositionsRepository(_pb);
      final posizioniDelGiorno = await posRepo.fetchPositionsByDate(date);

      // Trasformiamo le posizioni nel formato accettato dal calcolatore matematico
      final posizioniPerCalcolo =
          posizioniDelGiorno.map((p) => {'lat': p.lat, 'lon': p.lon}).toList();

      double totalKm =
          PositionsRepository.calculateTotalDistance(posizioniPerCalcolo);

      return DailyStats(steps: totalSteps, km: totalKm, minutes: totalMinutes);
    } catch (e) {
      debugPrint('🛑 [ActivitiesRepository] Errore getDailyStatistics: $e');
      return DailyStats.empty();
    }
  }

  // Metodo statico per convertire il JSON precaricato dalla Splash in un DailyStats pulito
  static DailyStats parsePreloadedData(List<dynamic> attivitaList) {
    int totalSteps = 0;
    int totalMinutes = 0;
    double totalKm = 0.0;

    for (var act in attivitaList) {
      // Gestiamo il caso in cui la Splash passi direttamente oggetti di tipo Activities
      if (act.runtimeType.toString() == 'Activities' ||
          act is! Map && act is! RecordModel) {
        // Poiché non possiamo importare il modello Activities qui senza rischiare dipendenze circolari
        // o errori di cast, leggiamo i dati dinamicamente tramite "duck typing" di Dart.
        try {
          totalSteps += (act.totalSteps ?? 0) as int;

          DateTime? startTime = act.startTime;
          DateTime? endTime = act.endTime;

          if (startTime != null) {
            endTime ??= DateTime.now().toUtc();
            totalMinutes += endTime.difference(startTime).inMinutes;
          }

          // Se il tuo modello Activities espone un campo 'km', scommenta la riga sotto
          // totalKm += act.km ?? 0.0;
        } catch (e) {
          debugPrint("Errore parsing oggetto Activities: $e");
        }
        continue;
      }

      // Codice originale per Mappe o RecordModel (in caso la Splash venga modificata in futuro)
      final map =
          act is RecordModel ? act.toJson() : act as Map<String, dynamic>;

      totalSteps += (map['total_steps'] ?? 0) as int;

      String? startStr = map['start_time'];
      String? endStr = map['end_time'];

      if (startStr != null && startStr.isNotEmpty) {
        DateTime startTime = DateTime.parse(startStr);
        DateTime endTime = (endStr != null && endStr.isNotEmpty)
            ? DateTime.parse(endStr)
            : DateTime.now().toUtc();

        totalMinutes += endTime.difference(startTime).inMinutes;
      }

      if (map['km'] != null) {
        totalKm += double.tryParse(map['km'].toString()) ?? 0.0;
      }
    }

    return DailyStats(steps: totalSteps, km: totalKm, minutes: totalMinutes);
  }
}
