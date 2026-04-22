import 'package:pocketbase/pocketbase.dart';

class Boards{
  final String id;
  final String userID;

  Boards({
    required this.id,
    required this.userID,
  });

  /// Factory per convertire un RecordModel grezzo in un oggetto tipizzato.
  factory Boards.fromRecord(RecordModel record) {
    return Boards(
      id: record.id,
      userID: record.getStringValue('user_id'),
    );
  }

  /// Converte l'oggetto in JSON per eventuali operazioni di scrittura.
  Map<String, dynamic> toJson() {
    return {
      'user_id': userID
    };
  }
}