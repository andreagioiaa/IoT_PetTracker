import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'dart:async'; // <-- 1. NUOVO IMPORT NECESSARIO PER GLI STREAM

class NgrokClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['ngrok-skip-browser-warning'] = 'true';
    return _inner.send(request);
  }
}

// URL PULITO (Rimosso /_/#/login)
final pb = PocketBase(
  'https://harvey-chairless-shenna.ngrok-free.dev',
  httpClientFactory: () => NgrokClient(),
);

bool isReady = false;

// ==========================================
// 📡 IL NOSTRO "CANALE RADIO" (STREAM)
// ==========================================

// Creiamo il controller dello Stream. "Broadcast" significa che più
// pagine possono "ascoltare" la diretta contemporaneamente senza darsi fastidio.
final StreamController<RecordModel> _streamController =
    StreamController<RecordModel>.broadcast();

// Questa è la variabile pubblica che le pagine UI ascolteranno
Stream<RecordModel> get posizioneStream => _streamController.stream;

/// Si iscrive al database e resta in ascolto
Future<void> avviaAscoltoInTempoReale() async {
  try {
    // Ci sintonizziamo su TUTTI i cambiamenti ('*') della tabella 'positions_test'
    pb.collection('positions_test').subscribe('*', (e) {
      print('📡 [STREAM] È arrivato un nuovo pacchetto! Azione: ${e.action}');

      // Quando arriva un nuovo record, lo inseriamo nel canale radio
      if (e.record != null) {
        _streamController.add(e.record!);
      }
    });
    print('✅ In ascolto continuo su positions_test...');
  } catch (e) {
    print('❌ Errore durante l\'avvio dello stream: $e');
  }
}

// ==========================================
// 🔑 AUTENTICAZIONE E AVVIO
// ==========================================

Future<bool> autenticazione() async {
  try {
    print('🔑 Autenticazione Superuser (v0.36.6) in corso...');

    await pb.collection('_superusers').authWithPassword(
          'nadalmattia.kennedy@gmail.com',
          'Pocketbase26#',
        );

    print('✅ Superuser autenticato: ${pb.authStore.model?.id}');
    isReady = true;

    // <-- 2. MAGIA: Appena entriamo nell'app, accendiamo l'ascolto in tempo reale!
    await avviaAscoltoInTempoReale();

    return true;
  } catch (e) {
    print('❌ Errore Auth: $e');
    return false;
  }
}

// ==========================================
// 📊 LETTURE STATICHE (Servono per la prima volta che apri l'app)
// ==========================================

Future<int?> getUltimoLivelloBatteria() async {
  if (!isReady) {
    print('⏳ Attesa autenticazione prima di leggere la batteria...');
    await Future.delayed(const Duration(seconds: 1));
    if (!isReady) return null;
  }

  try {
    final result = await pb.collection('positions_test').getList(
          page: 1,
          perPage: 1,
          sort: '-timestamp',
        );

    if (result.items.isEmpty) return null;

    return result.items.first.getIntValue('battery');
  } catch (e) {
    print('🛑 Errore lettura batteria: $e');
    return null;
  }
}

Future<DateTime?> getUltimoTimestamp() async {
  try {
    final result = await pb.collection('positions_test').getList(
          page: 1,
          perPage: 1,
          sort: '-timestamp',
        );

    if (result.items.isEmpty) return null;

    String timeStr = result.items.first.getStringValue('timestamp');
    return DateTime.parse(timeStr).toLocal();
  } catch (e) {
    print('🛑 Errore recupero timestamp: $e');
    return null;
  }
}
