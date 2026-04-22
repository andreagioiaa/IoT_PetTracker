import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart'; // <-- 1. IMPORT NECESSARIO PER PERSISTENZA
import 'splash_screen.dart';
import 'home.dart'; // Necessario per accedere a mapFocusPreference
import 'scambio.dart' as scambio;
import 'package:intl/date_symbol_data_local.dart';

void main() async {
  // 1. 🏗️ Obbligatorio per eseguire codice asincrono prima di runApp
  WidgetsFlutterBinding.ensureInitialized();

  // 2. 🌍 INIZIALIZZAZIONE LOCALIZZAZIONE (Risolve il crash LocaleDataException)
  // Questo "accende il motore" per i nomi dei mesi e giorni in italiano
  print('🌍 Inizializzazione dati di localizzazione per it_IT...');
  try {
    await initializeDateFormatting('it_IT', null);
    print('✅ Localizzazione inizializzata correttamente.');
  } catch (e) {
    print('⚠️ Errore durante l\'inizializzazione della localizzazione: $e');
  }

  // 3. 🔐 Caricamento variabili d'ambiente dal file .env
  print('🔐 Caricamento variabili d\'ambiente dal file .env...');
  try {
    await dotenv.load(fileName: ".env");
    print('✅ File .env caricato.');
  } catch (e) {
    print('⚠️ Errore caricamento .env: $e');
  }

  // --- 💾 LOGICA DI PERSISTENZA PREFERENZE (SharedPreferences) ---
  print('💾 Recupero preferenze locali dal dispositivo...');
  try {
    final prefs = await SharedPreferences.getInstance();
    final String? savedFocus = prefs.getString('map_focus_priority');
    
    if (savedFocus != null) {
      // Assicurati che mapFocusPreference sia accessibile (es. importata da home.dart)
      mapFocusPreference.value = savedFocus;
      print('✅ Focus mappa impostato su: $savedFocus');
    } else {
      print('ℹ️ Nessuna preferenza salvata, utilizzo default: Animale');
    }
  } catch (e) {
    print('⚠️ Errore nel caricamento delle preferenze locali: $e');
  }

  // --- 🔑 LOGICA DI AUTENTICAZIONE (PocketBase + SecureStorage) ---
  print('🏁 Avvio sistema: inizializzazione PocketBase...');
  
  // Inizializziamo il client usando l'URL dal .env
  scambio.inizializzaClient();

  /* Eseguiamo l'autenticazione UNA SOLA VOLTA.
     Questa funzione carica il token JWT dal SecureStorage e prova il refresh.
     Restituisce true se il server risponde (anche se l'utente non è loggato).
  */
  bool canConnect = await scambio.autenticazione();
  print(canConnect ? '✅ Connessione al server riuscita.' : '❌ Errore di connessione al server.');

  // 4. 🚀 Lanciamo l'app una sola volta passandogli lo stato della connessione
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