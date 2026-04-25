import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/splash_view.dart';
import 'screens/home.dart';
import 'services/authentication.dart' as scambio;
import 'services/notification.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0. 🔔 Inizializza Firebase Messaging e gestori
  await NotificationService.init();

  // 1. 🌍 Localizzazione
  try {
    await initializeDateFormatting('it_IT', null);
    print('✅ Localizzazione it_IT pronta.');
  } catch (e) {
    print('⚠️ Errore localizzazione: $e');
  }

  // 2. 🔐 Variabili d'ambiente
  try {
    await dotenv.load(fileName: ".env");
    print('✅ File .env caricato.');
  } catch (e) {
    print('⚠️ Errore .env: $e');
  }

  // 3. 💾 Preferenze Locali (Mappa)
  try {
    final prefs = await SharedPreferences.getInstance();
    final String? savedFocus = prefs.getString('map_focus_priority');
    if (savedFocus != null) {
      mapFocusPreference.value = savedFocus;
    }
  } catch (e) {
    print('⚠️ Errore SharedPreferences: $e');
  }

  // 4. 🏁 PocketBase Auth & Sync Token
  scambio.inizializzaClient();
  bool canConnect = await scambio.autenticazione();

  if (canConnect && scambio.pb.authStore.isValid) {
    print('✅ Autenticato come: ${scambio.pb.authStore.model.id}');

    // Sincronizza il token FCM con PocketBase
    await NotificationService.syncToken();
  } else {
    print('❌ Errore connessione o sessione non valida.');
  }

  runApp(PetTrackerApp(isAuthSuccessful: canConnect));
}

class PetTrackerApp extends StatelessWidget {
  final bool isAuthSuccessful;
  const PetTrackerApp({super.key, required this.isAuthSuccessful});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pet Tracker',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: !isAuthSuccessful
          ? _buildErrorScreen()
          : SplashScreen(isAlreadyAuthenticated: scambio.pb.authStore.isValid),
    );
  }

  Widget _buildErrorScreen() {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 60, color: Colors.red),
            SizedBox(height: 20),
            Text('Errore di connessione',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                  'Verifica il tunnel ngrok o le credenziali nel file .env.',
                  textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
