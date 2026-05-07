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
      return null; // 404 gestito silenziosamente (nessuna attività attiva) o errore critico (es. connessione)
    }
  }

  // Mapping delle attività per una data specifica
  Future<List<Activities>> fetchActivitiesByDate(
      String boardId, DateTime date) async {
    try {
      final startOfDay = DateTime(date.year, date.month, date.day, 0, 0, 0)
          .toUtc()
          .toIso8601String();
      final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

      // -start_time per ordinare dalla più recente alla più vecchia
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

  // Recupera l'ultimo oggetto Activities completo per la board
  Future<Activities?> _getLastActivity(String boardId) async {
    try {
      final result = await _pb.collection('activities').getList(
            page: 1,
            perPage: 1,
            filter: 'board_id = "$boardId"',
            sort: '-start_time',
          );

      // Verifica se c'è stato un risultato valido prima di accedere al primo elemento
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
      _pb.collection('activities').unsubscribe("*");

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

  // Rimuove la sottoscrizione alle attività
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
        return "Animale scappato";
      case 'w':
        return "In passeggiata";
      case 'v':
        return "In viaggio";
      // Questi casi verranno letti SOLO dalla Home
      case 'p':
        return "Animale scappato (Fermo)";
      case 'a':
        return "Fermo in viaggio";
      case 'z':
        return "Fermo in passeggiata";
      case 'd':
        final nomeZona = await _getNomeZonaDaPosizione(attivita.id);
        return nomeZona != null
            ? 'Fermo a $nomeZona'
            : 'Fermo in zona sconosciuta';
      case 'i':
        final nomeZona = await _getNomeZonaDaPosizione(attivita.id);
        return nomeZona ?? 'Zona sconosciuta';
      default:
        return 'Sconosciuta';
    }
  }

  // Metodo helper per recuperare le coordinate e calcolare il nome della zona
  Future<String?> _getNomeZonaDaPosizione(String activityId) async {
    try {
      final result = await _pb.collection('positions').getFirstListItem(
            'activity = "$activityId"',
          );
      final lat = result.getDoubleValue('lat');
      final lon = result.getDoubleValue('lon');

      return await PositionGpsService.calcolaZonaDalPunto(LatLng(lat, lon));
    } catch (e) {
      // Se fallisce (es. nessuna posizione trovata), restituisce null
      return null;
    }
  }

  // Recupera l'etichetta testuale e la configurazione UI se c'è un'attività attiva, altrimenti ritorna valori di default
  Future<Map<String, dynamic>> getActivityStatus(String boardId) async {
    try {
      final Activities? ultimaAttivita = await _getLastActivity(boardId);

      if (ultimaAttivita == null) {
        return {
          'titolo': 'Nessuna attività',
          'colore': Colors.grey,
          'icona': Icons.help_outline
        };
      }

      // Passa l'oggetto reale a getActivityLabel per la decodifica del titolo
      String titoloAttivita = await getActivityLabel(ultimaAttivita);

      // Ritorna la mappa completa passando l'attività e il titolo ricavato
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
      case 'p':
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

  // Recupera solo lo stato dell'ultima attività per un dato boardId, o 'n' se non c'è nessuna attività
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
      final start =
          DateTime(date.year, date.month, date.day).toUtc().toIso8601String();
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59)
          .toUtc()
          .toIso8601String();

      // Scarica TUTTE le attività di questa board per il giorno selezionato
      final records = await _pb.collection('activities').getFullList(
            filter:
                'board_id = "$boardId" && start_time >= "$start" && start_time <= "$end"',
          );

      int totalSteps = 0;
      int totalMinutes = 0;

      // Cicla ogni attività del giorno per sommare Passi e Minuti
      for (var record in records) {
        // Somma i passi
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

      // Calcolo dei Km totali sfruttando il PositionsRepository
      final posRepo = PositionsRepository(_pb);
      final posizioniDelGiorno =
          await posRepo.fetchPositionsByDate(date, boardId);

      // Trasforma le posizioni nel formato accettato dal metodo di calcolo della distanza (lista di mappe con lat e lon)
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
      // Gestisce il caso in cui la Splash passi direttamente oggetti di tipo Activities
      if (act.runtimeType.toString() == 'Activities' ||
          act is! Map && act is! RecordModel) {
        // Se l'oggetto è già un'istanza di Activities, accede direttamente ai suoi campi
        try {
          totalSteps += (act.totalSteps ?? 0) as int;

          DateTime? startTime = act.startTime;
          DateTime? endTime = act.endTime;

          if (startTime != null) {
            endTime ??= DateTime.now().toUtc();
            totalMinutes += endTime.difference(startTime).inMinutes;
          }
        } catch (e) {
          debugPrint("Errore parsing oggetto Activities: $e");
        }
        continue;
      }

      // Codice originale per Mappe o RecordModel
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
