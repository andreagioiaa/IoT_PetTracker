import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/login.dart';

// ==============================================
//      COSTANTI E CONFIGURAZIONI COLLEZIONI
// ==============================================

const String tabella_users = "users";
const String tabella_activities = "activities";
const String tabella_batteryData = "battery_data";
const String tabella_boards = "boards";
const String tabella_geofences = "geofences";
const String tabella_positions = "positions_duplicate";
const String tabella_positions_duplicate = "positions_duplicate";

// ==============================================
//   CONFIGURAZIONE DELLO STORE PERSONALIZZATO
// ==============================================

// Store personalizzato che salva i dati in modo sicuro
class SecureAuthStore extends AuthStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _storageKey = "pb_auth";

  Future<void> load() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw != null) {
      final Map<String, dynamic> decoded = jsonDecode(raw);
      final String token = decoded["token"] ?? "";
      final Map<String, dynamic>? modelMap = decoded["model"];

      RecordModel? model;
      if (modelMap != null) {
        model = RecordModel.fromJson(modelMap);
      }

      super.save(token, model);
    }
  }

  // Salva i dati in modo sicuro
  @override
  void save(String token, dynamic model) {
    super.save(token, model);
    final encoded = jsonEncode({"token": token, "model": model});
    _storage.write(key: _storageKey, value: encoded);
  }

  // Rimuove i dati dallo storage
  @override
  void clear() {
    super.clear();
    _storage.delete(key: _storageKey);
  }
}

final secureStore = SecureAuthStore();

// Client personalizzato per evitare il warning di ngrok
class NgrokClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['ngrok-skip-browser-warning'] = 'true';
    return _inner.send(request);
  }
}

bool isReady = false;

// ==============================================
//  LOGICA DI INIZIALIZZAZIONE E AUTENTICAZIONE
// ==============================================

// Rendiamo pb 'late': verrà inizializzato solo quando lo decidiamo noi
late PocketBase pb;

// Funzione per inizializzare il client DOPO che il .env è pronto
void inizializzaClient() {
  final url = dotenv.env['PB_URL'] ?? 'http://127.0.0.1:8090';
  pb = PocketBase(
    url,
    httpClientFactory: () => NgrokClient(),
    authStore: secureStore,
  );
  print('🚀 Client PocketBase inizializzato su: $url');
}

// Funzione di autenticazione che prova a ripristinare la sessione esistente
Future<bool> autenticazione() async {
  try {
    // 1. Carica lo store
    await secureStore.load();

    // 2. Se c'è un token, prova il refresh
    if (pb.authStore.isValid) {
      try {
        await pb.collection('users').authRefresh();
        isReady = true;
        print('✅ Sessione utente ripristinata.');
      } catch (e) {
        pb.authStore.clear();
        print('⚠️ Sessione scaduta.');
      }
    }
    return true; // Server raggiungibile
  } catch (e) {
    print('❌ Errore critico: $e');
    return false;
  }
}

// Funzione per eseguire il logout, pulendo lo store e navigando alla schermata di login
void eseguiLogout(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (pb.authStore.model != null) {
    await prefs.remove('fcm_token_sent_${pb.authStore.model!.id}');
  }

  pb.authStore.clear();
  isReady = false;

  print(
      "✅ Logout effettuato con pulizia flag alle ${DateTime.now().hour}:${DateTime.now().minute}");

  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (context) => const AuthScreen()),
    (route) => false,
  );
}
