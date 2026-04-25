import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter/material.dart';

class Geocoding {
  static const String _userAgent = 'PetTrackerApp_IoT_Project';

  /// Trasforma coordinate (Lat, Lon) in una stringa indirizzo pronta per l'interfaccia
  static Future<String?> getAddressFromCoordinates(LatLng loc) async {
    final details = await getAddressDetailsFromCoordinates(loc);
    if (details.isNotEmpty) {
      String street = details['street']!;
      String civic = details['civic']!;
      String city = details['city']!;
      String cap = details['cap']!;

      String result = "$city ($cap) - $street";
      if (civic.isNotEmpty) result += ", $civic";
      return result;
    }
    return null;
  }

  /// Trasforma coordinate in dettagli separati (utile per riempire i TextField)
  static Future<Map<String, String>> getAddressDetailsFromCoordinates(
      LatLng loc) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=${loc.latitude}&lon=${loc.longitude}&format=json&addressdetails=1');

    try {
      final response = await http.get(url, headers: {'User-Agent': _userAgent});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['address'] != null) {
          final address = data['address'];
          return {
            'street': address['road'] ??
                address['street'] ??
                address['pedestrian'] ??
                address['square'] ??
                'Via Sconosciuta',
            'civic': address['house_number'] ?? '',
            'city': address['city'] ??
                address['town'] ??
                address['village'] ??
                address['municipality'] ??
                'Città Sconosciuta',
            'cap': address['postcode'] ?? '00000',
          };
        }
      }
    } catch (e) {
      debugPrint("Errore reverse geocoding: $e");
    }
    return {};
  }

  /// Trasforma un indirizzo testuale in coordinate (Lat, Lon)
  static Future<Map<String, dynamic>> getCoordinatesFromAddress({
    required String rawStreet,
    required String rawCivic,
    required String rawCity,
    required String rawCap,
  }) async {
    final url = Uri.parse('https://nominatim.openstreetmap.org/search?'
        'street=${Uri.encodeComponent("$rawCivic $rawStreet")}'
        '&city=${Uri.encodeComponent(rawCity)}'
        '&postalcode=${Uri.encodeComponent(rawCap)}'
        '&format=json&addressdetails=1&limit=1');

    try {
      final response = await http.get(url, headers: {'User-Agent': _userAgent});
      if (response.statusCode == 200) {
        List data = json.decode(response.body);
        if (data.isNotEmpty) {
          var addressDetails = data[0]['address'] ?? {};
          return {
            'success': true,
            'street': addressDetails['road'] ??
                addressDetails['pedestrian'] ??
                addressDetails['square'] ??
                rawStreet,
            'civic': addressDetails['house_number'] ?? rawCivic,
            'city': addressDetails['city'] ??
                addressDetails['town'] ??
                addressDetails['village'] ??
                addressDetails['municipality'] ??
                rawCity,
            'cap': addressDetails['postcode'] ?? rawCap,
            'center': LatLng(
                double.parse(data[0]['lat']), double.parse(data[0]['lon']))
          };
        }
        return {
          'success': false,
          'error': "Indirizzo inesistente sulla mappa."
        };
      }
      return {
        'success': false,
        'error': "Errore di connessione al servizio mappe."
      };
    } catch (e) {
      return {'success': false, 'error': "Errore di rete: $e"};
    }
  }
}
