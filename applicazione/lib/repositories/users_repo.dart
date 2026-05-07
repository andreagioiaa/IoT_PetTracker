import 'package:pocketbase/pocketbase.dart';
import '../services/authentication.dart';
import '../models/users.dart';
import 'package:flutter/material.dart';
import "../screens/login.dart";

class UsersRepository {
  // Cerca il record della board associata all'utente e restituisce l'ID della board
  Future<String?> getBoardIdFromBoards() async {
    try {
      if (!pb.authStore.isValid || pb.authStore.model == null) return null;

      final userId = pb.authStore.model!.id;

      // Usiamo l'operatore '~' (contiene) per gestire il caso in cui 'user' sia una relazione o un array di relazioni
      final record = await pb.collection('boards').getFirstListItem(
            'user ~ "$userId"',
          );

      return record.getStringValue('board');
    } catch (e) {
      debugPrint('🚨 Errore getBoardIdFromBoards: $e');
      return null;
    }
  }

  // Legge lo stato dell'allarme dalla board associata all'utente
  Future<bool> getAlarmFromBoard() async {
    try {
      if (!pb.authStore.isValid || pb.authStore.model == null) return false;
      final userId = pb.authStore.model!.id;

      // Cerchiamo il record nella collezione 'boards' dove il campo 'user' contiene l'ID utente
      final record = await pb.collection('boards').getFirstListItem(
            'user ~ "$userId"',
          );

      return record.getBoolValue('alarm');
    } catch (e) {
      debugPrint('🚨 [users_repo]: Errore lettura allarme dalla board: $e');
      return false;
    }
  }

  // Aggiorna lo stato dell'allarme sulla board
  Future<bool> setBoardAlarm(bool value) async {
    try {
      if (!pb.authStore.isValid || pb.authStore.model == null) return false;
      final userId = pb.authStore.model!.id;

      final record = await pb.collection('boards').getFirstListItem(
            'user ~ "$userId"',
          );
      await pb.collection('boards').update(record.id, body: {
        'alarm': value,
      });

      print(
          "🚨[user_repo] nuovo valore per \"alarm\" nella collection \"board\": " +
              value.toString());
      return true;
    } catch (e) {
      debugPrint(
          '🚨[users_repo]: Errore aggiornamento allarme sulla board: $e');
      return false;
    }
  }

  // Recupera la data di creazione della board
  Future<DateTime?> getBoardCreationDate() async {
    try {
      if (!pb.authStore.isValid || pb.authStore.model == null) return null;

      final userId = pb.authStore.model!.id;

      final record = await pb.collection('boards').getFirstListItem(
            'user ~ "$userId"',
          );

      // PocketBase salva in automatico la data nel campo 'created'
      if (record.created.isNotEmpty) {
        return DateTime.parse(record.created);
      }
      return null;
    } catch (e) {
      debugPrint('🚨 Errore getBoardCreationDate: $e');
      return null;
    }
  }

  // Registra un nuovo utente su PocketBase e lo collega alla board
  Future<String?> register(String email, String password, String name,
      String surname, String username, String boardIdInput) async {
    String? createdUserId; // Variabile per il rollback in caso di errore

    try {
      final cleanBoardId = boardIdInput.trim();
      if (cleanBoardId.isEmpty) return "Codice Board vuoto.";

      // 1. VERIFICA BOARD (Public View Rule: id != "")
      RecordModel board;
      try {
        // Usiamo getOne perché ora la View Rule è aperta e conosciamo l'ID
        board = await pb.collection('boards').getOne(cleanBoardId);
        print("[DEBUG] Board verificata: ${board.id}");
      } catch (e) {
        print("[ERROR] Board non trovata o permessi mancanti: $e");
        return "Codice Board inesistente o non accessibile.";
      }

      // 2. CREAZIONE UTENTE
      final userBody = {
        'email': email,
        'password': password,
        'passwordConfirm': password,
        'name': name,
        'surname': surname,
        'username': username,
        'role': 'user',
        'alarm': false,
        'boardId': board.id,
      };

      RecordModel userRecord;
      try {
        userRecord = await pb.collection('users').create(body: userBody);
        createdUserId = userRecord.id;
        print("[DEBUG] Utente creato con ID: $createdUserId");
      } catch (e) {
        return "Errore: Email o Username potrebbero essere già in uso.";
      }

      // 3. LOGIN (Necessario per l'autorizzazione all'update della board)
      try {
        await pb.collection('users').authWithPassword(email, password);
        print("[DEBUG] Login effettuato con successo.");
      } catch (e) {
        // Se il login fallisce, eliminiamo l'utente per coerenza
        await pb.collection('users').delete(createdUserId);
        return "Errore critico durante l'autenticazione.";
      }

      // 4. AGGIORNAMENTO BOARD (Associazione Utente)
      try {
        // Verifichiamo la validità del token prima di procedere
        if (!pb.authStore.isValid) throw Exception("Token non valido");

        // Usiamo l'operatore '+' per aggiungere l'ID alla lista esistente senza sovrascriverla
        // Questo richiede che la 'Update Rule' su PB sia @request.auth.id != ""
        await pb.collection('boards').update(board.id, body: {
          'user+': userRecord.id,
        });

        print("[SUCCESS] Utente collegato correttamente alla board.");
        return null; // Tutto completato con successo!
      } catch (e) {
        // 🛑 ROLLBACK: Se l'associazione fallisce, eliminiamo l'account
        // "L'utente dev'essere eliminato, non deve continuare ad esistere sul DB"
        if (createdUserId != null) {
          await pb.collection('users').delete(createdUserId);
          pb.authStore.clear(); // Puliamo la sessione fallita
          print(
              "[ROLLBACK] Utente eliminato per errore associazione board: $e");
        }
        return "Errore nell'attivazione della Board. Registrazione annullata.";
      }
    } catch (e) {
      debugPrint('🛑 Errore Imprevisto in register: $e');
      return "Si è verificato un errore imprevisto.";
    }
  }

  // Recupera i dati dell'utente corrente trasformandoli nel modello User
  Future<User?> getCurrentUser() async {
    if (!pb.authStore.isValid || pb.authStore.model == null) return null;
    try {
      // Recuperiamo il record aggiornato dal server per evitare dati obsoleti
      final record =
          await pb.collection('users').getOne(pb.authStore.model!.id);
      return User.fromRecord(record);
    } catch (e) {
      print('🛑 Errore recupero utente: $e');
      return null;
    }
  }

  // Restituisce lo stato dell'allarme (necessario per home.dart)
  Future<bool?> getAlarmStatus() async {
    final user = await getCurrentUser();
    return user?.alarm;
  }

  // Aggiorna lo stato dell'allarme sul database (necessario per home.dart)
  Future<bool> updateAlarm(bool status) async {
    try {
      if (!pb.authStore.isValid) return false;
      await pb.collection('users').update(pb.authStore.model!.id, body: {
        'alarm': status,
      });
      return true;
    } catch (e) {
      print('🛑 Errore updateAlarm: $e');
      return false;
    }
  }

  // Aggiorna i dati anagrafici
  Future<bool> updateProfile(String name, String surname) async {
    try {
      if (!pb.authStore.isValid) return false;
      await pb.collection('users').update(pb.authStore.model!.id, body: {
        'name': name,
        'surname': surname,
      });
      return true;
    } catch (e) {
      print('🛑 Errore updateProfile: $e');
      return false;
    }
  }

  // Aggiorna la password ed effettua il re-login automatico
  // PocketBase invalida il token quando la password cambia, quindi il re-auth è d'obbligo
  Future<bool> updatePassword(String oldPassword, String newPassword) async {
    try {
      if (!pb.authStore.isValid) return false;

      final userId = pb.authStore.model!.id;
      final email = pb.authStore.model!.getStringValue('email');

      await pb.collection('users').update(userId, body: {
        'oldPassword': oldPassword,
        'password': newPassword,
        'passwordConfirm': newPassword,
      });

      // Re-login silenzioso per rinfrescare il token
      return await login(email, newPassword);
    } catch (e) {
      print('🛑 Errore updatePassword: $e');
      return false;
    }
  }

  // Effettua il logout pulendo lo store e riportando l'utente al login
  void eseguiLogout(BuildContext context) {
    // Pulisce il PocketBase authStore
    logout();

    // Rimuove tutte le rotte e torna al Login
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const AuthScreen()),
      (route) => false,
    );
  }

  // Effettua il logout pulendo lo store
  void logout() {
    pb.authStore.clear();
  }

  // Effettua il login e aggiorna la variabile globale isReady in scambio.dart
  Future<bool> login(String identity, String password) async {
    try {
      // PocketBase gestisce il token internamente: dopo questa chiamata,
      // il token viene salvato nel secureStore configurato in authentication.dart
      await pb
          .collection('users')
          .authWithPassword(identity.trim(), password.trim());

      if (pb.authStore.isValid) {
        isReady = true;
        return true;
      }
      return false;
    } catch (e) {
      print('🚨 Errore Login Utente: $e');
      return false;
    }
  }

  // Permette di sottoscriversi ai cambiamenti in tempo reale di una specifica board
  // Restituisce una funzione per annullare la sottoscrizione (unsubscribe)
  Future<void> subscribeToBoardUpdates(
      String recordId, Function(Map<String, dynamic>) onUpdate) async {
    try {
      await pb.collection('boards').subscribe(recordId, (e) {
        if (e.action == 'update' && e.record != null) {
          onUpdate(e.record!.toJson());
        }
      });
      print(
          "📡 [users_repo]: Sottoscrizione Real-time attiva per board: $recordId");
    } catch (e) {
      print("🚨 [users_repo]: Errore sottoscrizione Real-time: $e");
    }
  }

  // Utility per disiscriversi da un record specifico
  void unsubscribeFromBoard(String recordId) {
    pb.collection('boards').unsubscribe(recordId);
    print("🔌 [users_repo]: Sottoscrizione rimossa per board: $recordId");
  }
}
