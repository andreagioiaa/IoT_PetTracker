import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/globals/app_state.dart';
import 'authentication.dart' as scambio;

class PositionGpsService {
  // Controlla e richiede i permessi di localizzazione, mostrando un pop-up esplicativo del motivo della richiesta
  static Future<void> richiediPermessi(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    bool giaChiesto = prefs.getBool('permesso_posizione_chiesto') ?? false;

    LocationPermission permission = await Geolocator.checkPermission();

    // Se i permessi sono disabilitati del tutto nel telefono
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('GPS disattivato dal dispositivo.');
      hasLocationPermission.value = false;
      return;
    }

    if (permission == LocationPermission.denied) {
      // Se è la prima volta che lo chiediamo, mostriamo un nostro pop-up per spiegare perché serve il GPS
      if (!giaChiesto && context.mounted) {
        await _mostraPopUpSpiegazione(context);
        await prefs.setBool('permesso_posizione_chiesto', true);
      }

      // Richiesta di sistema effettiva
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      // L'utente ha bloccato i permessi per sempre
      debugPrint('Permessi negati permanentemente.');
      hasLocationPermission.value = false;
      return;
    }

    hasLocationPermission.value = (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse);
  }

  // Mostra un dialog personalizzato per spiegare all'utente perché serve il GPS
  static Future<void> _mostraPopUpSpiegazione(BuildContext context) async {
    // Calcoliamo lo scale in base all'altezza dello schermo
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
            Icon(Icons.location_on,
                color: const Color(0xFF00C6B8), size: 24 * scale),
            SizedBox(width: 10 * scale),
            Text('Permesso GPS',
                style: TextStyle(
                    fontSize: 20 * scale, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'Per calcolare la distanza tra te e il tuo animale e per usare le zone di sicurezza, abbiamo bisogno di accedere alla tua posizione.',
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

  // Ottiene la posizione attuale dell'utente, se i permessi sono stati concessi
  static Future<Position?> ottieniPosizioneUtente() async {
    if (!hasLocationPermission.value) return null;
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      debugPrint('Errore nel recupero posizione utente: $e');
      return null;
    }
  }

  // ==============================================
  //        LOGICA MATEMATICA E GEOFENCING
  // ==============================================

  /// Calcola in quale zona si trova attualmente il punto fornito
  static Future<String> calcolaZonaDalPunto(LatLng petPos) async {
    try {
      final geoResult = await scambio.pb.collection('geofences').getFullList();
      for (var record in geoResult) {
        if (record.getBoolValue('is_active') == true) {
          List<LatLng> polygonPts = [];
          final rawList = record.getListValue<dynamic>('vertices');

          for (var pt in rawList) {
            if (pt is List && pt.length >= 2) {
              polygonPts.add(LatLng(double.parse(pt[0].toString()),
                  double.parse(pt[1].toString())));
            }
          }

          if (polygonPts.length >= 3 &&
              isPointInsidePolygon(petPos, polygonPts)) {
            return record.getStringValue('name');
          }
        }
      }
      return "Fuori zona sicura";
    } catch (e) {
      debugPrint('Errore nel calcolo della zona: $e');
      return "Errore rilevamento";
    }
  }

  // Algoritmo Ray-Casting per verificare se un punto è dentro un poligono
  static bool isPointInsidePolygon(LatLng point, List<LatLng> polygon) {
    bool isInside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      if (((polygon[i].latitude > point.latitude) !=
              (polygon[j].latitude > point.latitude)) &&
          (point.longitude <
              (polygon[j].longitude - polygon[i].longitude) *
                      (point.latitude - polygon[i].latitude) /
                      (polygon[j].latitude - polygon[i].latitude) +
                  polygon[i].longitude)) {
        isInside = !isInside;
      }
      j = i;
    }
    return isInside;
  }
}
