import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/splash_view.dart';
import 'screens/home.dart';
import 'services/scambio.dart' as scambio;
import 'package:intl/date_symbol_data_local.dart';

// --- GESTIONE BACKGROUND FIREBASE ---
// Serve a Firebase per "svegliarsi" e gestire la notifica se l'app è completamente chiusa
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print(
      "📩 Ricevuto messaggio in background (Batteria scarica!): ${message.messageId}");
}
// ------------------------------------

void main() async {
  // 1. 🏗️ Obbligatorio per eseguire codice asincrono prima di runApp
  WidgetsFlutterBinding.ensureInitialized();

  print('🔥 Inizializzazione Firebase e Notifiche...');
  try {
    await Firebase.initializeApp();

    // Diciamo a Firebase quale funzione usare in background
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    FirebaseMessaging messaging = FirebaseMessaging.instance;

    // Richiediamo i permessi all'utente
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    print('🔔 Permessi notifiche concessi: ${settings.authorizationStatus}');

    // Recuperiamo l'indirizzo univoco del telefono (Token)
    String? token = await messaging.getToken();
    print("📲 IL TOKEN DI QUESTO TELEFONO È: $token");
  } catch (e) {
    print('⚠️ Errore inizializzazione Firebase: $e');
  }

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

  // --- LOGICA DI AUTENTICAZIONE (PocketBase + SecureStorage) ---
  print('🏁 Avvio sistema: inizializzazione PocketBase...');

  scambio.inizializzaClient();

  bool canConnect = await scambio.autenticazione();
  print(canConnect
      ? '✅ Connessione al server riuscita.'
      : '❌ Errore di connessione al server.');

  // --- SALVATAGGIO TOKEN SU POCKETBASE ---
  // SOLO se l'utente è loggato con successo
  if (canConnect && scambio.pb.authStore.isValid) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = scambio.pb.authStore.model!.id; // ID univoco dell'utente corrente
      
      // Creiamo una chiave specifica per questo utente
      final String flagKey = 'fcm_token_sent_$userId';
      bool tokenGiaInviato = prefs.getBool(flagKey) ?? false;

      if (!tokenGiaInviato) {
        print('🚀 Primo accesso per l\'utente $userId: invio token FCM...');
        
        String? currentToken = await FirebaseMessaging.instance.getToken();

        if (currentToken != null) {
          await scambio.pb.collection('users').update(
            userId,
            body: {'tokenFCM': currentToken},
          );
          
          // Salviamo il flag per QUESTO specifico utente
          await prefs.setBool(flagKey, true);
          print('✅ Token salvato per l\'utente $userId');
        }
      } else {
        print('ℹ️ Token già presente per questo account. Skip.');
      }
    } catch (e) {
      print('⚠️ Errore gestione token: $e');
    }
  }
  // -------------------------------------------

  // Lanciamo l'app una sola volta passandogli lo stato della connessione
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
