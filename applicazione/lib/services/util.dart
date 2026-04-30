import 'package:flutter/material.dart';

// ritorna l'orario corretto sulla base UTC del nostro DB PocketBase (ora è corretta e ultimata: NON TOCCARE!)
String formattaOra(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return "N.D.";

  final oraLocale = DateTime.now();

  // Se il dato è nel futuro (es. -69 min), sappiamo che Flutter ha aggiunto 2 ore di troppo.
  // Sottraiamo 2 ore per tornare all'orario reale della board.
  DateTime dataReale = ultimoInvio;
  if (oraLocale.difference(ultimoInvio).inMinutes < -30) {
    dataReale = ultimoInvio.subtract(const Duration(hours: 2));
  }

  final differenza = oraLocale.difference(dataReale);

  if (differenza.isNegative) return "Adesso";
  if (differenza.inSeconds < 60) return "Adesso";
  if (differenza.inMinutes < 60) return "${differenza.inMinutes} min fa";
  if (differenza.inHours < 24) return "${differenza.inHours} ore fa";

  return "${dataReale.day}/${dataReale.month}/${dataReale.year}";
}

// ritorna le dimensioni di scale dello schermo
double dimensioniSchermo(BuildContext context){
  return (MediaQuery.of(context).size.height / 800).clamp(0.7, 1.2);
}


String formattaTempoMinuti(int minuti) {
  if (minuti == 0) return "0 min";
  if (minuti < 60) return "$minuti min";
  final int ore = minuti ~/ 60;
  final int minRestanti = minuti % 60;
  if (minRestanti == 0) return "${ore}h";
  return "${ore}h ${minRestanti}m";
}


/*
funzione che torna un   Map<String, dynamic> _dailyStats = {
    'steps': 0,
    'km': "0.0",
    'minutes': 0,
  };

  void _elaboraAttivita(List<dynamic> attivita) {
    int passiTotali = 0;
    Duration durataTotale = Duration.zero;

    for (var act in attivita) {
      passiTotali += (act.totalSteps as int);
      if (act.startTime != null && act.endTime != null) {
        durataTotale += act.endTime!.difference(act.startTime!);
      }
    }

    double kmTotali = (passiTotali * 0.7) / 1000;

    if (mounted) {
      setState(() {
        _dailyStats = {
          'steps': passiTotali,
          'km': kmTotali.toStringAsFixed(1),
          'minutes': durataTotale.inMinutes,
        };
      });
    }
  }
*/

// Aggiungi questo alla fine di util.dart (o dove preferisci)

class DailyStats {
  // Singleton pattern
  static final DailyStats _instance = DailyStats._internal();
  factory DailyStats() => _instance;
  DailyStats._internal();

  int passiTotali = 0;
  String kmTotali = "0.0";
  int minutiTotali = 0;

  // Costante centralizzata per il calcolo dei Km
  static const double _moltiplicatorePassiKm = 0.7;

  /// Calcola le statistiche da una LISTA di attività (usato in home.dart)
  void elaboraListaAttivita(List<dynamic> attivita) {
    int tempPassi = 0;
    Duration durataTotale = Duration.zero;

    for (var act in attivita) {
      tempPassi += (act.totalSteps as int);
      
      if (act.startTime != null && act.endTime != null) {
        durataTotale += act.endTime!.difference(act.startTime!);
      } else if (act.isActive == true && act.startTime != null) {
         // Se l'attività è attiva consideriamo fino al momento attuale
         durataTotale += DateTime.now().difference(act.startTime!);
      }
    }

    _aggiornaValori(tempPassi, durataTotale);
  }

  /// Calcola le statistiche da una SINGOLA attività (usato in activity_details.dart)
  void elaboraSingolaAttivita(dynamic attivita) {
    int tempPassi = attivita.totalSteps;
    Duration durata = Duration.zero;

    if (attivita.startTime != null && attivita.endTime != null) {
      durata = attivita.endTime!.difference(attivita.startTime!);
    } else if (attivita.startTime != null) {
      // Se l'attività è ancora in corso
      durata = DateTime.now().difference(attivita.startTime!);
    }

    _aggiornaValori(tempPassi, durata);
  }

  /// Metodo interno per centralizzare l'assegnazione
  void _aggiornaValori(int passi, Duration durata) {
    passiTotali = passi;
    double calcoloKm = (passi * _moltiplicatorePassiKm) / 1000;
    kmTotali = calcoloKm.toStringAsFixed(1);
    minutiTotali = durata.inMinutes;
  }

  /// Ritorna una mappa per compatibilità rapida
  Map<String, dynamic> toMap() {
    return {
      'steps': passiTotali,
      'km': kmTotali,
      'minutes': minutiTotali,
    };
  }
}