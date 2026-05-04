import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// Converte l'orario UTC in orario locale
DateTime? _correggiFusoOrario(DateTime? orario) {
  if (orario == null) return null;
  return orario.toLocal();
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
