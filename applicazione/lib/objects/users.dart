import 'package:pocketbase/pocketbase.dart';

/// Rappresenta un utente registrato nella collezione "users" di PocketBase.
class User {
  final String id;
  final String email;
  final bool emailVisibility;
  final String username;
  final bool verified;
  final String name;
  final String surname;
  final bool alarm;
  final DateTime created;
  final DateTime updated;

  User({
    required this.id,
    required this.email,
    required this.emailVisibility,
    required this.username,
    required this.verified,
    required this.name,
    required this.surname,
    required this.alarm,
    required this.created,
    required this.updated,
  });

  /// Factory method per creare un oggetto User da un RecordModel di PocketBase.
  factory User.fromRecord(RecordModel record) {
    return User(
      id: record.id,
      email: record.getStringValue('email'),
      emailVisibility: record.getBoolValue('emailVisibility'),
      username: record.getStringValue('username'),
      verified: record.getBoolValue('verified'),
      name: record.getStringValue('name'),
      surname: record.getStringValue('surname'),
      alarm: record.getBoolValue('alarm'),
      // Gestione delle date con conversione al fuso orario locale.
      created: DateTime.parse(record.created).toLocal(),
      updated: DateTime.parse(record.updated).toLocal(),
    );
  }

  /// Converte i dati modificabili in una mappa per le operazioni di update.
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'surname': surname,
      'alarm': alarm,
      'emailVisibility': emailVisibility,
    };
  }
}