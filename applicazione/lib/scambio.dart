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

// Aggiungi questa funzione in scambio.dart

/// Effettua il login utilizzando l'identità (Email o Username) e la Password.
Future<bool> loginUtente(String identity, String password) async {
  try {
    // PocketBase gestisce automaticamente sia email che username nel primo parametro
    final authData = await pb.collection('user').authWithPassword(
      identity.trim(), 
      password.trim(),
    );

    if (pb.authStore.isValid) {
      print('✅ Utente autenticato: ${pb.authStore.model.id}');
      isReady = true; 
      
      // Avviamo lo stream per le posizioni una volta loggati
      await avviaAscoltoInTempoReale();
      return true;
    }
    return false;
  } catch (e) {
    print('❌ Errore Login PocketBase: $e');
    return false;
  }
}


/// Se non è loggato, restituisce una stringa di default.
Future<String> getNomeUtente() async {
  try {
    // Verifichiamo se c'è un modello utente valido nell'authStore
    if (pb.authStore.isValid && pb.authStore.model != null) {
      // Usiamo getStringValue per estrarre il campo 'name'
      final nome = pb.authStore.model!.getStringValue('name');
      return nome.isNotEmpty ? nome : 'Utente';
    }
    return 'Ospite';
  } catch (e) {
    print('❌ Errore getNomeUtente: $e');
    return 'Errore';
  }
}

/// Recupera il cognome dell'utente loggato.
Future<String> getCognomeUtente() async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      // Estraiamo il campo 'surname'
      final cognome = pb.authStore.model!.getStringValue('surname');
      return cognome.isNotEmpty ? cognome : '';
    }
    return '';
  } catch (e) {
    print('❌ Errore getCognomeUtente: $e');
    return 'Errore';
  }
}

Future<String> getNomeCompleto() async {
  // Aspettiamo i risultati di entrambi i Future
  final nome = await getNomeUtente();
  final cognome = await getCognomeUtente();

  // Usiamo l'interpolazione di stringhe e .trim() 
  // per evitare spazi doppi se il cognome è vuoto
  return '$nome $cognome'.trim();
}


/// Aggiorna lo stato dell'allarme su PocketBase per l'utente corrente.
Future<bool> setAllarme(bool nuovoStato) async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      final userId = pb.authStore.model!.id;
      
      // Aggiorniamo il record nella collezione 'user'
      await pb.collection('user').update(userId, body: {
        'alarm': nuovoStato,
      });
      
      print('✅ Allarme aggiornato su PB: $nuovoStato');
      return true;
    }
    return false;
  } catch (e) {
    print('❌ Errore setAllarme: $e');
    return false;
  }
}

/// Restituisce lo stato dell'allarme. 
/// Ritorna [true/false] se il dato è letto correttamente.
/// Ritorna [null] se c'è un errore o l'utente non è autenticato.
Future<bool?> getAllarme() async {
  try {
    // Verifichiamo l'autenticazione tramite l'authStore
    if (pb.authStore.isValid && pb.authStore.model != null) {
      
      // 1. Recuperiamo il valore come booleano direttamente
      // Nota: Assicurati che il campo si chiami 'alarm' su PocketBase
      final record = pb.authStore.model!;
      
      // Verifichiamo se il campo esiste effettivamente nel modello caricato
      if (!record.data.containsKey('alarm')) {
        print('⚠️ Campo "alarm" non trovato nella collezione user');
        return null; 
      }

      return record.getBoolValue('alarm');
    }
    
    print('⚠️ Tentativo di lettura allarme senza sessione valida.');
    return null; 
  } catch (e) {
    print('❌ Errore critico getAllarme: $e');
    return null; // Qui capisci che è un errore di sistema
  }
}


Future<bool> registraUtente(String email, String password, String name, String surname, String username) async {
  try {
    final body = {
      'email': email,
      'password': password,
      'passwordConfirm': password,
      'name': name,
      'surname': surname,
      'username': username,
      'role': 'user',
      'alarm': false,
    };

    await pb.collection('user').create(body: body);
    print('✅ Utente registrato: $email');
    return true;
  } catch (e) {
    print('❌ Errore Registrazione: $e');
    return false;
  }
}