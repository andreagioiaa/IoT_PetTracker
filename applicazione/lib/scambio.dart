import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

class NgrokClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['ngrok-skip-browser-warning'] = 'true';
    return _inner.send(request);
  }
}

// 1. URL PULITO (Rimosso /_/#/login)
final pb = PocketBase(
  'https://harvey-chairless-shenna.ngrok-free.dev',
  httpClientFactory: () => NgrokClient(),
);

bool isReady = false;

Future<bool> autenticazione() async {
  try {
    print('🔑 Autenticazione Superuser (v0.36.6) in corso...');
    
    // 2. NUOVA SINTASSI: Puntiamo alla collezione di sistema _superusers
    await pb.collection('_superusers').authWithPassword(
      'nadalmattia.kennedy@gmail.com',
      'Pocketbase26#',
    );

    print('✅ Superuser autenticato: ${pb.authStore.model?.id}');
    isReady = true;
    return true;
    
  } catch (e) {
    print('❌ Errore Auth: $e');
    // Se ricevi ancora 404 qui, controlla che la tua email 
    // sia effettivamente presente nella collezione _superusers su PocketBase
    return false;
  }
}

Future<int?> getUltimoLivelloBatteria() async {
  // Se non siamo ancora autenticati, aspettiamo un attimo o ritentiamo
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

/// Recupera il timestamp dell'ultimo invio registrato.
Future<DateTime?> getUltimoTimestamp() async {
  try {
    final result = await pb.collection('positions_test').getList(
      page: 1,
      perPage: 1,
      sort: '-timestamp', // Sempre l'ultimo record basato sul tempo
    );

    if (result.items.isEmpty) return null;

    // Recuperiamo la stringa e la trasformiamo in un oggetto DateTime locale
    String timeStr = result.items.first.getStringValue('timestamp');
    return DateTime.parse(timeStr).toLocal();
    
  } catch (e) {
    print('🛑 Errore recupero timestamp: $e');
    return null;
  }
}