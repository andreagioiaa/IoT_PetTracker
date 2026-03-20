import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'splash_screen.dart';
import 'home.dart';
import 'scambio.dart' as scambio;

void main() async {
  // 1. Necessario per eseguire codice asincrono prima di runApp
  WidgetsFlutterBinding.ensureInitialized();

  print('🏁 Avvio sistema: inizializzazione PocketBase...');

  // 2. Eseguiamo l'autenticazione PRIMA di caricare l'interfaccia.
  // Questo garantisce che quando i widget verranno costruiti,
  // il client PocketBase avrà già il token salvato.
  bool isAuthenticated = await scambio.autenticazione();

  // 3. Lanciamo l'app passando il risultato dell'autenticazione
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
        useMaterial3: true, // Ti consiglio di attivarlo per un look moderno
      ),
      // Se l'autenticazione fallisce (es. ngrok spento), mostriamo un errore invece della Home
      home: !isAuthSuccessful
          ? _buildErrorScreen()
          : (kDebugMode ? const PetTrackerNavigation() : const SplashScreen()),
    );
  }

  // Una piccola schermata di emergenza se il server non risponde
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
            Text('Controlla se il tunnel ngrok è attivo.'),
          ],
        ),
      ),
    );
  }
}
