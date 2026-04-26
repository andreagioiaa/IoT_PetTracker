import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'authentication.dart' as scambio;

// ==============================================
//         GESTIONE BACKGROUND FIREBASE
// ==============================================

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

  /// Inizializza Firebase e imposta gli ascoltatori (eseguito nel main.dart)
  static Future<void> init() async {
    try {
      await Firebase.initializeApp();

      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print(
            '📩 Messaggio foreground ricevuto: ${message.notification?.title}');
      });
    } catch (e) {
      print('⚠️ Errore inizializzazione Firebase Notifications: $e');
    }
  }

  /// Mostra il pop-up e richiede i permessi per le notifiche (eseguito nella Home)
  static Future<void> richiediPermessi(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    bool giaChiesto = prefs.getBool('permesso_notifiche_chiesto') ?? false;

    // 1. MOSTRIAMO IL NOSTRO POP-UP A TUTTI (Solo la prima volta)
    if (!giaChiesto && context.mounted) {
      await _mostraPopUpSpiegazione(context);
      await prefs.setBool('permesso_notifiche_chiesto', true);
    }

    // 2. CONTROLLIAMO COSA SERVE AL SISTEMA OPERATIVO
    NotificationSettings currentSettings =
        await _messaging.getNotificationSettings();

    if (currentSettings.authorizationStatus ==
        AuthorizationStatus.notDetermined) {
      // Se il sistema operativo lo richiede (Android 13+ o iOS), mostriamo la richiesta ufficiale
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      print('🔔 Permessi notifiche: ${settings.authorizationStatus}');

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        await syncToken();
      }
    } else if (currentSettings.authorizationStatus ==
        AuthorizationStatus.authorized) {
      // Se era già autorizzato (es. Android 12), sincronizziamo direttamente il token!
      await syncToken();
    }
  }

  /// Il Pop-Up personalizzato
  static Future<void> _mostraPopUpSpiegazione(BuildContext context) async {
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.65, 1.2);

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20 * scale)),
        title: Row(
          children: [
            Icon(Icons.notifications_active,
                color: const Color(0xFF00C6B8), size: 24 * scale),
            SizedBox(width: 10 * scale),
            Text('Notifiche',
                style: TextStyle(
                    fontSize: 18 * scale, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'Per avvisarti immediatamente se il tuo animale esce da un\'Area Sicura o se la batteria è scarica, abbiamo bisogno di inviarti delle notifiche.',
          style: TextStyle(fontSize: 15 * scale),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C6B8),
              padding: EdgeInsets.symmetric(
                  horizontal: 16 * scale, vertical: 10 * scale),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10 * scale),
              ),
            ),
            onPressed: () => Navigator.pop(context),
            child: Text('Ho capito',
                style: TextStyle(color: Colors.white, fontSize: 14 * scale)),
          ),
        ],
      ),
    );
  }

  /// Recupera il token FCM e lo salva (in una lista) su PocketBase se l'utente è autenticato
  static Future<void> syncToken() async {
    try {
      String? nuovoToken = await _messaging.getToken();

      if (nuovoToken != null && scambio.pb.authStore.isValid) {
        final userId = scambio.pb.authStore.model.id;

        // 1. Recuperiamo l'utente attuale dal database
        final userRecord = await scambio.pb.collection('users').getOne(userId);

        // 2. Leggiamo la lista dei token attuali (gestendo il caso in cui sia vuota)
        List<String> tokensList = [];
        try {
          final rawList = userRecord.getListValue<dynamic>('tokenFCM');
          tokensList = rawList.map((e) => e.toString()).toList();
        } catch (_) {
          // Se il campo è vuoto o c'è un errore di lettura, partiamo con una lista vuota
        }

        // 3. Controlliamo se questo telefono è già registrato nella lista
        if (!tokensList.contains(nuovoToken)) {
          // Non c'è! Lo aggiungiamo alla lista
          tokensList.add(nuovoToken);

          // 4. Salviamo la lista aggiornata su PocketBase
          await scambio.pb.collection('users').update(
            userId,
            body: {'tokenFCM': tokensList},
          );
          print('✅ Nuovo FCM Token salvato nella lista su PocketBase.');
        } else {
          print(
              '⚡ Il token di questo dispositivo è già presente nel database.');
        }
      }
    } catch (e) {
      print('⚠️ Errore sincronizzazione token FCM su PocketBase: $e');
    }
  }
}
