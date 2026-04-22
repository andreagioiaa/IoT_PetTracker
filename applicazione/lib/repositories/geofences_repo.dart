import 'package:pocketbase/pocketbase.dart';
import 'package:latlong2/latlong.dart';
import '../services/scambio.dart';

class GeofenceRepository {
  final PocketBase _pb;

  GeofenceRepository(this._pb);

  /// Recupera tutte le zone e gestisce il parsing dei vertici
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

  Future<bool> deleteGeofence(String id) async {
    try {
      await _pb.collection('geofences').delete(id);
      return true;
    } catch (e) {
      return false;
    }
  }
}
