import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // <-- NUOVO IMPORT

class NgrokClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['ngrok-skip-browser-warning'] = 'true';
    return _inner.send(request);
  }
}

// 🔐 URL PRESO DAL FILE .ENV
final pb = PocketBase(
  dotenv.env['PB_URL'] ?? 'URL_MANCANTE',
  httpClientFactory: () => NgrokClient(),
);

bool isReady = false;

// ==========================================
// 📡 IL NOSTRO "CANALE RADIO" (STREAM)
// ==========================================

final StreamController<RecordModel> _streamController =
    StreamController<RecordModel>.broadcast();

Stream<RecordModel> get posizioneStream => _streamController.stream;

Future<void> avviaAscoltoInTempoReale() async {
  try {
    pb.collection('positions_test').subscribe('*', (e) {
      print('📡 [STREAM] È arrivato un nuovo pacchetto! Azione: ${e.action}');

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
    print('🔑 Autenticazione Superuser in corso...');

    // 🔐 RECUPERO CREDENZIALI DAL FILE .ENV IN MODO SICURO
    final email = dotenv.env['PB_USER']!;
    final password = dotenv.env['PB_PASS']!;

    await pb.collection('_superusers').authWithPassword(email, password);

    print('✅ Superuser autenticato: ${pb.authStore.model?.id}');
    isReady = true;

    await avviaAscoltoInTempoReale();

    return true;
  } catch (e) {
    print('❌ Errore Auth: $e');
    return false;
  }
}

// ==========================================
// 📊 LETTURE STATICHE
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
