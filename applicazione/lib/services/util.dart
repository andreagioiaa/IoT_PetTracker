String formattaUltimoAggiornamento(DateTime? ultimoInvio) {
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