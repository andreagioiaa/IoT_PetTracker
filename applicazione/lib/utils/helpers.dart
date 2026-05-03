import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// Calcola e correggere l'orario UTC
DateTime? _correggiFusoOrario(DateTime? orario) {
  if (orario == null) return null;

  final oraLocale = DateTime.now();
  DateTime dataReale = orario;

  // Se il dato è nel futuro (es. -69 min) significa che è stato inviato in UTC e dobbiamo correggerlo
  // Sottrae 2 ore per tornare all'orario reale della board
  if (oraLocale.difference(orario).inMinutes < -30) {
    dataReale = orario.subtract(const Duration(hours: 2));
  }

  return dataReale;
}

// Ritorna l'orario in formato relativo (es. "10 min fa", "Adesso")
String formattaOra(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return "N.D.";

  final dataReale = _correggiFusoOrario(ultimoInvio)!;
  final oraLocale = DateTime.now();
  final differenza = oraLocale.difference(dataReale);

  if (differenza.isNegative) return "Adesso";
  if (differenza.inSeconds < 60) return "Adesso";
  if (differenza.inMinutes < 60) return "${differenza.inMinutes} min fa";
  if (differenza.inHours < 24) return "${differenza.inHours} h fa";

  return "${dataReale.day}/${dataReale.month}/${dataReale.year}";
}

// Ritorna l'orario in formato digitale esatto (es. "14:30")
String formattaOrarioEsatto(DateTime? orario) {
  final dataReale = _correggiFusoOrario(orario);
  if (dataReale == null) return "--:--";

  return DateFormat('HH:mm').format(dataReale);
}

// Ritorna le dimensioni di scale dello schermo
double dimensioniSchermo(BuildContext context) {
  return (MediaQuery.of(context).size.height / 800).clamp(0.7, 1.2);
}

// Formatta i minuti in ore e minuti (es. 125 min -> "2h 5m")
String formattaTempoMinuti(int minuti) {
  if (minuti == 0) return "0 min";
  if (minuti < 60) return "$minuti min";
  final int ore = minuti ~/ 60;
  final int minRestanti = minuti % 60;
  if (minRestanti == 0) return "${ore}h";
  return "${ore}h ${minRestanti}m";
}
