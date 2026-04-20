import 'package:pocketbase/pocketbase.dart';
import '../scambio.dart'; 
import '../objects/users.dart';

class UsersRepository {
  /// Effettua il login e restituisce l'esito.
  Future<bool> login(String identity, String password) async {
    try {
      await pb.collection('users').authWithPassword(identity.trim(), password.trim());
      return pb.authStore.isValid;
    } catch (e) {
      return false;
    }
  }

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
      return false;
    }
  }

  /// Recupera i dati dell'utente corrente trasformandoli nel modello User.
  Future<User?> getCurrentUser() async {
    if (!pb.authStore.isValid || pb.authStore.model == null) return null;
    // Recuperiamo il record aggiornato dal server
    final record = await pb.collection('users').getOne(pb.authStore.model!.id);
    return User.fromRecord(record);
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
      return false;
    }
  }

  /// Effettua il logout pulendo lo store.
  void logout() {
    pb.authStore.clear();
  }
}