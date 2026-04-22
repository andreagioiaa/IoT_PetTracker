import 'package:pocketbase/pocketbase.dart';
import '../scambio.dart';
import '../objects/users.dart';
import 'package:flutter/material.dart';
import "../login.dart";

class UsersRepository {
  /*
  /// Effettua il login e restituisce l'esito.
  Future<bool> login(String identity, String password) async {
    try {
      await pb.collection('users').authWithPassword(identity.trim(), password.trim());
      return pb.authStore.isValid;
    } catch (e) {
      print('🛑 Errore Login: $e');
      return false;
    }
  }*/

  /// Registra un nuovo utente su PocketBase.
  Future<bool> register(String email, String password, String name,
      String surname, String username) async {
    try {
      final body = {
        'email': email,
        'password': password,
        'passwordConfirm': password,
        'name': name,
        'surname': surname,
        'username': username,
        'role': 'user',
        'alarm': false,
      };
      await pb.collection('users').create(body: body);
      return true;
    } catch (e) {
      print('🛑 Errore Registrazione: $e');
      return false;
    }
  }

  /// Recupera i dati dell'utente corrente trasformandoli nel modello User.
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

  /// Restituisce lo stato dell'allarme (necessario per home.dart).
  Future<bool?> getAlarmStatus() async {
    final user = await getCurrentUser();
    return user?.alarm;
  }

  /// Aggiorna lo stato dell'allarme sul database (necessario per home.dart).
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

  /// Aggiorna i dati anagrafici.
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

  /// Aggiorna la password ed effettua il re-login automatico.
  /// PocketBase invalida il token quando la password cambia, quindi il re-auth è d'obbligo.
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

  /// Effettua il logout pulendo lo store e riportando l'utente al login
  void eseguiLogout(BuildContext context) {
    // 1. Pulisce il PocketBase authStore
    logout();

    // 2. Navigazione: rimuove tutte le rotte e torna al Login
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const AuthScreen()),
      (route) => false,
    );
  }

  /// Effettua il logout pulendo lo store
  void logout() {
    pb.authStore.clear();
  }

  // In users_repo.dart
  Future<bool> login(String identity, String password) async {
    try {
      // PocketBase gestisce il token internamente: dopo questa chiamata,
      // il token viene salvato nel secureStore configurato in scambio.dart
      await pb
          .collection('users')
          .authWithPassword(identity.trim(), password.trim());

      if (pb.authStore.isValid) {
        isReady = true; // Impostiamo la variabile globale in scambio.dart
        return true;
      }
      return false;
    } catch (e) {
      print('🚨 Errore Login Utente: $e');
      return false;
    }
  }
}
