import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'login.dart';

// --- COSTANTI TABELLE ---
const String tabella_users = "users"; // fields: id, password, tokenKey, email, emailVisibility, username, verified, name, surname, alarma, created, updated
const String tabella_activities = "activities"; // fields: id, board_id, total_steps, start_time, end_time, is_active
const String tabella_batteryData= "battery_data"; // fields: id, board_id, timestamp, battery, battery_percent, charging
const String tabella_boards = "boards"; // fields: id, user_id
const String tabella_data_sent_raw = "data_sent_raw"; // fields: id, board_id, timestamp, lon, lat, geo, battery, battery_percent, charging, steps, sleep, gps_valid
const String tabella_geofences = "geofences"; // fields: id, name, center_lon, center_lat, is_active, user_id, street, civic, city, cap, vertices (JSON), created, updated
const String tabella_positions = "positions"; // fields: id, timestamp, lon, lat, geo, battery, battery_percent, charging, feet, sleep
const String tabella_positions_duplicate = "positions_duplicate"; // fields: id, board_id, timestamp, lon, lat, geo, gps_valid, net_fail_count
// const String tabella_nometabella = "nometabella"; (copiare e incollare)

// --- PERSISTENZA SICURA DEL TOKEN ---
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

  @override
  void save(String token, dynamic model) {
    super.save(token, model);
    final encoded = jsonEncode({"token": token, "model": model});
    _storage.write(key: _storageKey, value: encoded);
  }

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

// 🔐 INIZIALIZZAZIONE POCKETBASE
// Legge solo l'URL dal file .env. Le credenziali admin non servono più qui.
/*
final pb = PocketBase(
  dotenv.env['PB_URL'] ?? 'http://127.0.0.1:8090',
  httpClientFactory: () => NgrokClient(),
  authStore: secureStore,
);*/

bool isReady = false;

// ==========================================
// 🔑 LOGICA DI AUTENTICAZIONE (STATELESS)
// ==========================================

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

// ==========================================
// 🛠️ UTILITY DI LOGOUT
// ==========================================

void eseguiLogout(BuildContext context) {
  pb.authStore.clear();
  isReady = false;

  print("✅ Logout effettuato alle ${DateTime.now().hour}:${DateTime.now().minute}");

  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (context) => const AuthScreen()),
    (route) => false,
  );
}