import 'dart:convert'; // Necessario per jsonEncode/Decode
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pet_tracker/screens/login.dart';
import 'package:pocketbase/pocketbase.dart';
import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:typed_data';

// --- NUOVA CLASSE PER LA PERSISTENZA SICURA ---
class SecureAuthStore extends AuthStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _storageKey = "pb_auth";

  Future<void> load() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw != null) {
      final Map<String, dynamic> decoded = jsonDecode(raw);
      final String token = decoded["token"] ?? "";
      final Map<String, dynamic>? modelMap = decoded["model"];

      // 🛠️ FIX: Trasformiamo la mappa nel formato RecordModel richiesto
      RecordModel? model;
      if (modelMap != null) {
        model = RecordModel.fromJson(modelMap);
      }

      // Ora super.save riceve (String, RecordModel?) invece di (String, Map)
      super.save(token, model);
    }
  }

  @override
  void save(String token, dynamic model) {
    super.save(token, model);
    // Quando salviamo, PocketBase passa già un RecordModel,
    // jsonEncode userà automaticamente il suo metodo .toJson()
    final encoded = jsonEncode({"token": token, "model": model});
    _storage.write(key: _storageKey, value: encoded);
  }

  @override
  void clear() {
    super.clear();
    _storage.delete(key: _storageKey);
  }
}

// Inizializziamo lo store prima del client
final secureStore = SecureAuthStore();

class NgrokClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['ngrok-skip-browser-warning'] = 'true';
    return _inner.send(request);
  }
}

// 🔐 URL e STORE SICURO
final pb = PocketBase(
  dotenv.env['PB_URL'] ?? 'URL_MANCANTE',
  httpClientFactory: () => NgrokClient(),
  authStore: secureStore, // <-- IMPORTANTE: Colleghiamo lo store qui
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
    // 1. Carichiamo i dati salvati (se esistono)
    await secureStore.load();

    // 2. Verifichiamo se abbiamo già una sessione valida
    if (pb.authStore.isValid) {
      print('🔐 Sessione recuperata! Verifica validità in corso...');
      try {
        // Opzionale: rinfresca il token per essere sicuri che sia ancora valido sul server
        await pb.collection('user').authRefresh();
        print('✅ Sessione valida per: ${pb.authStore.model?.id}');
        isReady = true;
        await avviaAscoltoInTempoReale();
        return true;
      } catch (e) {
        print('⚠️ Sessione scaduta o revocata, serve nuovo login.');
        pb.authStore.clear();
        return true; // Ritorniamo true perché il server è raggiungibile, ma l'app andrà al login
      }
    }

    // 3. Se non c'è sessione, controlliamo solo se il server risponde (superuser check rimosso per sicurezza utente)
    // Se vuoi mantenere il login automatico superuser (occhio ai rischi!), lascialo pure qui.
    print('👤 Nessuna sessione trovata. Reindirizzamento al login.');
    return true;
  } catch (e) {
    print('❌ Errore connessione Server: $e');
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

Future<bool> registraUtente(String email, String password, String name,
    String surname, String username) async {
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

/// Esegue il logout completo, pulendo memoria e archivio sicuro.
void eseguiLogout(BuildContext context) {
  // 1. Pulizia fisica del token e del modello (RAM + SecureStorage)
  pb.authStore.clear();

  // 2. Reset dello stato di prontezza dell'app
  isReady = false;

  print(
      "✅ Sessione terminata correttamente alle ore ${DateTime.now().hour}:${DateTime.now().minute}");

  // 3. Navigazione: "Svuota" lo stack delle pagine e torna al Login
  // Questo impedisce all'utente di tornare indietro con il tasto 'back'
  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (context) => const AuthScreen()),
    (route) => false,
  );
}

// Aggiungi queste funzioni in scambio.dart

/// Aggiorna i dati anagrafici dell'utente
Future<bool> aggiornaProfilo(String nuovoNome, String nuovoCognome) async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      final userId = pb.authStore.model!.id;
      await pb.collection('user').update(userId, body: {
        'name': nuovoNome,
        'surname': nuovoCognome,
      });
      print('✅ Profilo aggiornato: $nuovoNome $nuovoCognome');
      return true;
    }
    return false;
  } catch (e) {
    print('❌ Errore aggiornaProfilo: $e');
    return false;
  }
}

/// Aggiorna la password dell'utente
Future<bool> aggiornaPassword(
    String vecchiaPassword, String nuovaPassword) async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      final userId = pb.authStore.model!.id;

      await pb.collection('user').update(userId, body: {
        'oldPassword': vecchiaPassword, // <--- RICHIESTO DA POCKETBASE
        'password': nuovaPassword,
        'passwordConfirm': nuovaPassword,
      });

      print('✅ Password aggiornata con successo');
      return true;
    }
    return false;
  } catch (e) {
    // Stampiamo l'errore completo per debugging, ma restituiamo false
    print('❌ Errore aggiornaPassword: $e');
    return false;
  }
}

/// Restituisce l'URL completo dell'avatar dell'utente loggato.
String getAvatarUrl() {
  if (pb.authStore.isValid && pb.authStore.model != null) {
    final record = pb.authStore.model!;
    final avatarName = record.getStringValue('avatar');

    if (avatarName.isEmpty) return "";

    final baseUrl = pb.files.getUrl(record, avatarName).toString();

    // Aggiungiamo un timestamp per evitare che la cache di Flutter ci mostri dati vecchi
    return "$baseUrl?t=${DateTime.now().millisecondsSinceEpoch}";
  }
  return "";
}

/// Carica un nuovo file avatar su PocketBase.
Future<bool> aggiornaAvatar(Uint8List imageBytes, String fileName) async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      final userId = pb.authStore.model!.id;

      await pb.collection('user').update(
        userId,
        files: [
          http.MultipartFile.fromBytes(
            'avatar',
            imageBytes,
            filename:
                fileName, // PocketBase ha bisogno di un nome file con estensione
          ),
        ],
      );
      return true;
    }
    return false;
  } catch (e) {
    print('❌ Errore aggiornaAvatar: $e');
    return false;
  }
}

/// Rimuove l'avatar dell'utente corrente su PocketBase.
Future<bool> rimuoviAvatar() async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      final userId = pb.authStore.model!.id;

      // Settando il campo avatar a null, PocketBase elimina il file fisico
      await pb.collection('user').update(userId, body: {'avatar': null});

      print('🗑️ Avatar rimosso per l\'utente: $userId');
      return true;
    }
    return false;
  } catch (e) {
    print('❌ Errore rimuoviAvatar: $e');
    return false;
  }
}

/*
Future<bool> rimuoviAvatar() async {
  try {
    if (pb.authStore.isValid && pb.authStore.model != null) {
      await pb.collection('user').update(pb.authStore.model!.id, body: {'avatar': null});
      return true;
    }
    return false;
  } catch (e) {
    return false;
  }
}
*/
