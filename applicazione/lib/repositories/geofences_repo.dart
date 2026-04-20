import '../scambio.dart';
import '../objects/geofences.dart';

class GeofenceRepository {
  Future<List<Geofences>> getMyGeofences() async {
    try {
      final result = await pb.collection('geofences').getList(
        filter: 'user_id = "${pb.authStore.model?.id}"',
      );
      return result.items.map((r) => Geofences.fromRecord(r)).toList();
    } catch (e) {
      return [];
    }
  }
}