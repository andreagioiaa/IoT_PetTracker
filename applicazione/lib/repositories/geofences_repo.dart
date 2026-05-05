import 'package:pocketbase/pocketbase.dart';
import 'package:latlong2/latlong.dart';
import '../services/position_gps.dart';

class GeofenceRepository {
  final PocketBase _pb;

  GeofenceRepository(this._pb);

  // Metodo per recuperare tutte le zone (usato principalmente per debug o funzioni avanzate)
  Future<List<RecordModel>> getFullList() async {
    return await _pb.collection('geofences').getFullList();
  }

  // Metodo unificato per salvare (Create o Update)
  Future<RecordModel> saveGeofence({
    String? id,
    required Map<String, dynamic> data,
  }) async {
    if (id != null) {
      return await _pb.collection('geofences').update(id, body: data);
    } else {
      return await _pb.collection('geofences').create(body: data);
    }
  }

  // Recupera tutte le zone e gestisce il parsing dei vertici
  Future<List<Map<String, dynamic>>> fetchGeofences() async {
    try {
      final records =
          await _pb.collection('geofences').getFullList(sort: '-created');

      return records.map((res) {
        List<LatLng> polygonPts = [];
        try {
          final rawList = res.getListValue<dynamic>('vertices');
          for (var pt in rawList) {
            if (pt is List && pt.length >= 2) {
              polygonPts.add(LatLng(double.parse(pt[0].toString()),
                  double.parse(pt[1].toString())));
            }
          }
        } catch (e) {/* Gestione silenziosa vertici mancanti */}

        return {
          "id": res.id,
          "name": res.getStringValue('name'),
          "street": res.getStringValue('street'),
          "civic": res.getStringValue('civic'),
          "city": res.getStringValue('city'),
          "cap": res.getStringValue('cap'),
          "center": LatLng(res.getDoubleValue('center_lat'),
              res.getDoubleValue('center_lon')),
          "is_active": res.getBoolValue('is_active'),
          "vertices": polygonPts,
        };
      }).toList();
    } catch (e) {
      print("🛑 Errore fetchGeofences: $e");
      return [];
    }
  }

  // Aggiorna solo lo stato attivo di una zona (utile per toggle rapido)
  Future<bool> updateActiveStatus(String id, bool isActive) async {
    try {
      await _pb
          .collection('geofences')
          .update(id, body: {"is_active": isActive});
      return true;
    } catch (e) {
      return false;
    }
  }

  // Elimina una zona
  Future<bool> deleteGeofence(String id) async {
    try {
      await _pb.collection('geofences').delete(id);
      return true;
    } catch (e) {
      return false;
    }
  }

  // Determina se un punto è dentro una zona attiva e restituisce il nome della zona o "Fuori zona sicura"
  Future<String> getZoneForPoint(LatLng point) async {
    try {
      final geofences = await fetchGeofences();
      for (var zone in geofences) {
        if (zone['is_active'] == true) {
          final List<LatLng> vertices = zone['vertices'];
          if (vertices.length >= 3 &&
              PositionGpsService.isPointInsidePolygon(point, vertices)) {
            return zone['name'];
          }
        }
      }
      return "Fuori zona sicura";
    } catch (e) {
      return "Errore rilevamento";
    }
  }

  // Aggiorna i dati (inclusi i vertici) di una zona esistente
  Future<bool> updateGeofenceVertices(
      String id, Map<String, dynamic> body) async {
    try {
      await _pb.collection('geofences').update(id, body: body); //
      return true;
    } catch (e) {
      print("🛑 Errore updateGeofenceVertices: $e");
      return false;
    }
  }

  // Crea una nuova zona e restituisce il suo ID
  Future<String?> createGeofence(Map<String, dynamic> body) async {
    try {
      final record = await _pb.collection('geofences').create(body: body); //
      return record.id;
    } catch (e) {
      print("🛑 Errore createGeofence: $e");
      return null;
    }
  }
}
