import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart'; // <-- 1. IMPORT NECESSARIO PER PERSISTENZA
import 'splash_screen.dart';
import 'home.dart'; // Necessario per accedere a mapFocusPreference
import 'scambio.dart' as scambio;

void main() async {
  // 1. Necessario per eseguire codice asincrono prima di runApp
  WidgetsFlutterBinding.ensureInitialized();

  // 2. CARICHIAMO IL FILE SEGRETO
  print('🔐 Caricamento variabili d\'ambiente dal file .env...');
  await dotenv.load(fileName: ".env");

  // --- 💾 INIZIO LOGICA DI PERSISTENZA ---
  print('💾 Recupero preferenze locali dal dispositivo...');
  try {
    final prefs = await SharedPreferences.getInstance();
    // Cerchiamo la chiave 'map_focus_priority' (la stessa che userai in settings.dart)
    final String? savedFocus = prefs.getString('map_focus_priority');
    
    if (savedFocus != null) {
      // Sovrascriviamo il valore di default ('Animale') con quello salvato dall'utente
      mapFocusPreference.value = savedFocus;
      print('✅ Focus mappa impostato su: $savedFocus');
    } else {
      print('ℹ️ Nessuna preferenza salvata, utilizzo default: Animale');
    }
  } catch (e) {
    print('⚠️ Errore nel caricamento delle preferenze: $e');
  }
  // --- FINE LOGICA DI PERSISTENZA ---

  print('🏁 Avvio sistema: inizializzazione PocketBase...');

  // 3. Eseguiamo l'autenticazione
  bool isAuthenticated = await scambio.autenticazione();

  // 4. Lanciamo l'app
  runApp(PetTrackerApp(isAuthSuccessful: isAuthenticated));
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
      // Se il server non risponde, mostriamo l'errore. 
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
            Text('Impossibile connettersi al server.',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 40, vertical: 10),
              child: Text(
                'Controlla se il tunnel ngrok è attivo o i dati di accesso nel file .env.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}