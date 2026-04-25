import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'authentication.dart' as scambio;

// ==============================================
//         GESTIONE BACKGROUND FIREBASE
// ==============================================

// IMPORTANTE: Questa funzione DEVE rimanere fuori da qualsiasi classe (top-level)
// per poter essere eseguita in background isolata dal resto dell'app.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print("📩 Messaggio background ricevuto: ${message.messageId}");
}

// ==============================================
//          GESTIONE SERVIZIO NOTIFICHE
// ==============================================

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// Inizializza Firebase, richiede i permessi e imposta gli ascoltatori
  static Future<void> init() async {
    try {
      await Firebase.initializeApp();

      // Imposta il gestore per l'app in background/chiusa
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);

      // Richiede i permessi (fondamentale specialmente per iOS)
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      print('🔔 Permessi notifiche: ${settings.authorizationStatus}');

      // Gestione messaggi in foreground (quando l'app è aperta)
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print(
            '📩 Messaggio foreground ricevuto: ${message.notification?.title}');
        // Qui in futuro potrai mostrare una snackbar o un alert personalizzato
      });
    } catch (e) {
      print('⚠️ Errore inizializzazione Firebase Notifications: $e');
    }
  }

  /// Recupera il token FCM e lo salva su PocketBase se l'utente è autenticato
  static Future<void> syncToken() async {
    try {
      String? token = await _messaging.getToken();
      print("📲 Token FCM attuale: $token");

      if (token != null && scambio.pb.authStore.isValid) {
        await scambio.pb.collection('users').update(
          scambio.pb.authStore.model.id,
          body: {'tokenFCM': token},
        );
        print('✅ FCM Token sincronizzato su PocketBase.');
      }
    } catch (e) {
      print('⚠️ Errore sincronizzazione token FCM su PocketBase: $e');
    }
  }
}
