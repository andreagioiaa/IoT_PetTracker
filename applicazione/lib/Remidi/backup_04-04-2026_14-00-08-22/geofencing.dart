import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'scambio.dart' as scambio;
import 'polygon_editor.dart';
import 'home.dart';

enum ActiveCard { none, zone, user, pet }

class GeofencingScreen extends StatefulWidget {
  const GeofencingScreen({super.key});

  @override
  State<GeofencingScreen> createState() => _GeofencingScreenState();
}

class _GeofencingScreenState extends State<GeofencingScreen> {
  List<Map<String, dynamic>> savedPlaces = [];
  bool isLoading = true;

  LatLng? _petLocation;
  StreamSubscription? _streamSubscription;

  final ValueNotifier<ActiveCard> _activeCard =
      ValueNotifier<ActiveCard>(ActiveCard.none);
  String _userAddress = "Rilevamento indirizzo in corso...";
  String _petAddress = "Rilevamento indirizzo in corso...";

  // Variabile per capire se l'utente ha modificato l'indirizzo trovato dal GPS
  String _indirizzoPrecompilatoGps = "";

  @override
  void initState() {
    super.initState();
    _caricaZoneDalDatabase();

    _streamSubscription = scambio.posizioneStream.listen((nuovoRecord) {
      debugPrint('🗺️ [MAPPA] Il tubo ha vibrato! Aggiorno la zampetta...');
      try {
        final lat = nuovoRecord.getDoubleValue('lat');
        final lon = nuovoRecord.getDoubleValue('lon');

        if (mounted) {
          setState(() {
            _petLocation = LatLng(lat, lon);
          });
        }
      } catch (e) {
        debugPrint('❌ [MAPPA] Errore lettura coordinate in diretta: $e');
      }
    });

    _scaricaPosizioneInizialeAnimale();
    _determinePosition();
  }

  @override
  void dispose() {
    _activeCard.dispose();
    _streamSubscription?.cancel();
    super.dispose();
  }

  // ALGORITMO PER RILEVARE IL TOCCO DENTRO UN POLIGONO
  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    bool isInside = false;
    int i, j = polygon.length - 1;
    for (i = 0; i < polygon.length; i++) {
      if ((polygon[i].latitude > point.latitude) !=
              (polygon[j].latitude > point.latitude) &&
          point.longitude <
              (polygon[j].longitude - polygon[i].longitude) *
                      (point.latitude - polygon[i].latitude) /
                      (polygon[j].latitude - polygon[i].latitude) +
                  polygon[i].longitude) {
        isInside = !isInside;
      }
      j = i;
    }
    return isInside;
  }

  Future<void> _scaricaPosizioneInizialeAnimale() async {
    if (!scambio.isReady) await scambio.autenticazione();

    try {
      final result = await scambio.pb.collection('positions_test').getList(
            page: 1,
            perPage: 1,
            sort: '-timestamp',
          );

      if (result.items.isNotEmpty && mounted && _petLocation == null) {
        final lat = result.items.first.getDoubleValue('lat');
        final lon = result.items.first.getDoubleValue('lon');
        setState(() {
          _petLocation = LatLng(lat, lon);
        });
      }
    } catch (e) {
      debugPrint("Errore recupero posizione iniziale pet: $e");
    }
  }

  Future<void> _caricaZoneDalDatabase({String? forceSelectId}) async {
    setState(() => isLoading = true);
    if (!scambio.isReady) await scambio.autenticazione();

    String? idAttuale = forceSelectId;
    if (idAttuale == null &&
        selectedPlaceIndex != null &&
        savedPlaces.isNotEmpty &&
        selectedPlaceIndex! < savedPlaces.length) {
      idAttuale = savedPlaces[selectedPlaceIndex!]['id'];
    }

    try {
      final records = await scambio.pb
          .collection('geofences_test')
          .getFullList(sort: '-created');

      final List<Map<String, dynamic>> nuoveZone = records.map((res) {
        List<LatLng> polygonPts = [];
        try {
          final rawList = res.getListValue<dynamic>('vertices');
          for (var pt in rawList) {
            if (pt is List && pt.length >= 2) {
              polygonPts.add(LatLng(double.parse(pt[0].toString()),
                  double.parse(pt[1].toString())));
            }
          }
        } catch (e) {
          debugPrint('Nessun vertice trovato per ${res.id}');
        }

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

      // FIX ORDINAMENTO
      nuoveZone.sort((a, b) {
        bool isActiveA = a['is_active'] ?? false;
        bool isActiveB = b['is_active'] ?? false;

        if (isActiveA && !isActiveB) return -1;
        if (!isActiveA && isActiveB) return 1;

        return a['name']
            .toString()
            .toLowerCase()
            .compareTo(b['name'].toString().toLowerCase());
      });

      setState(() {
        savedPlaces = nuoveZone;
        isLoading = false;

        if (savedPlaces.isEmpty) {
          selectedPlaceIndex = null;
          if (_activeCard.value == ActiveCard.zone) {
            _activeCard.value = ActiveCard.none;
          }
        } else {
          if (idAttuale != null) {
            int nuovoIndice =
                savedPlaces.indexWhere((z) => z['id'] == idAttuale);
            if (nuovoIndice != -1) {
              selectedPlaceIndex = nuovoIndice;
              // Se abbiamo forzato l'id (es. appena salvato), mostriamo la card
              if (forceSelectId != null) {
                _activeCard.value = ActiveCard.zone;
              }
            } else {
              selectedPlaceIndex = null;
              if (_activeCard.value == ActiveCard.zone) {
                _activeCard.value = ActiveCard.none;
              }
            }
          } else {
            // Avvio pulito: nessuna area selezionata!
            selectedPlaceIndex = null;
          }
        }
      });
    } catch (e) {
      debugPrint("Errore caricamento: $e");
      setState(() => isLoading = false);
    }
  }

  Future<void> _resolveAddress(LatLng loc, bool isPet) async {
    setState(() {
      if (isPet)
        _petAddress = "Ricerca indirizzo in corso...";
      else
        _userAddress = "Ricerca indirizzo in corso...";
    });

    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=${loc.latitude}&lon=${loc.longitude}&format=json&addressdetails=1');

    try {
      final response = await http
          .get(url, headers: {'User-Agent': 'PetTrackerApp_IoT_Project'});

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['address'] != null) {
          final address = data['address'];

          String street = address['road'] ??
              address['pedestrian'] ??
              address['square'] ??
              'Via Sconosciuta';
          String civic = address['house_number'] ?? 'SNC';
          String city = address['city'] ??
              address['town'] ??
              address['village'] ??
              address['municipality'] ??
              'Città Sconosciuta';
          String cap = address['postcode'] ?? '00000';

          String result = "$city ($cap) - $street, $civic";

          setState(() {
            if (isPet)
              _petAddress = result;
            else
              _userAddress = result;
          });
          return;
        }
      }
    } catch (e) {
      debugPrint("Errore reverse geocoding on demand: $e");
    }

    setState(() {
      String coords =
          "Coordinate: ${loc.latitude.toStringAsFixed(4)}, ${loc.longitude.toStringAsFixed(4)}";
      if (isPet)
        _petAddress = coords;
      else
        _userAddress = coords;
    });
  }

  Future<void> _toggleZoneActiveStatus(String id, bool currentStatus) async {
    try {
      final newStatus = !currentStatus;
      await scambio.pb.collection('geofences_test').update(id, body: {
        "is_active": newStatus,
      });

      await _caricaZoneDalDatabase();

      geofenceUpdateSignal.value++;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newStatus ? "Area attivata." : "Area disattivata."),
          backgroundColor: newStatus ? Colors.green : Colors.orange,
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      debugPrint("Errore attivazione Area: $e");
    }
  }

  int? selectedPlaceIndex;
  final MapController _mapController = MapController();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _streetController = TextEditingController();
  final TextEditingController _civicController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  final TextEditingController _capController = TextEditingController();

  bool isSatelliteMap = false;
  LatLng? _myLocation;

  Future<void> _determinePosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('Servizi GPS disabilitati');

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Permessi negati');
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception('Permessi negati permanentemente');
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );

      if (mounted) {
        setState(() {
          _myLocation = LatLng(position.latitude, position.longitude);
        });

        _mapController.move(_myLocation!, 18.0);
        _activeCard.value = ActiveCard.user;
        _resolveAddress(_myLocation!, false);
      }
    } catch (e) {
      debugPrint("Errore geolocalizzazione: $e");
    }
  }

  Future<void> _promptAddLocation() async {
    if (_myLocation == null) {
      _indirizzoPrecompilatoGps = "";
      _showPlaceDialog(isEditing: false);
      return;
    }

    bool? useCurrentLocation = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Nuova Area Sicura"),
        content: const Text(
            "Vuoi creare un'Area basata esattamente sulla tua posizione attuale?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:
                const Text("No, manuale", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C6B8)),
            child: const Text("Sì, usa posizione",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (useCurrentLocation == null) return;

    if (useCurrentLocation) {
      await _performReverseGeocodingAndShowDialog();
    } else {
      _indirizzoPrecompilatoGps = "";
      _showPlaceDialog(isEditing: false);
    }
  }

  Future<void> _performReverseGeocodingAndShowDialog() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Rilevamento indirizzo in corso..."),
        duration: Duration(seconds: 1)));

    final lat = _myLocation!.latitude;
    final lon = _myLocation!.longitude;
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&addressdetails=1');

    String street = '';
    String civic = '';
    String city = '';
    String cap = '';

    try {
      final response = await http
          .get(url, headers: {'User-Agent': 'PetTrackerApp_IoT_Project'});

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['address'] != null) {
          final address = data['address'];
          street = address['road'] ??
              address['street'] ??
              address['square'] ??
              address['pedestrian'] ??
              '';
          civic = address['house_number'] ?? '';
          city = address['city'] ??
              address['town'] ??
              address['village'] ??
              address['municipality'] ??
              '';
          cap = address['postcode'] ?? '';
        }
      }
    } catch (e) {
      debugPrint("Errore reverse geocoding: $e");
    }

    _nameController.text = "Posizione Attuale";
    _streetController.text = street;
    _civicController.text = civic;
    _cityController.text = city;
    _capController.text = cap;

    _indirizzoPrecompilatoGps =
        "$street$civic$city$cap".toLowerCase().replaceAll(" ", "");

    _showPlaceDialog(isEditing: false, gpsLocation: _myLocation);
  }

  Future<Map<String, dynamic>> _fetchCoordinatesAndSaveOrUpdate(
      {bool isUpdating = false, int? updateIndex}) async {
    final String rawName = _nameController.text.trim();
    final String rawStreet = _streetController.text.trim();
    final String rawCivic = _civicController.text.trim();
    final String rawCity = _cityController.text.trim();
    final String rawCap = _capController.text.trim();

    final url = Uri.parse('https://nominatim.openstreetmap.org/search?'
        'street=${Uri.encodeComponent("$rawCivic $rawStreet")}'
        '&city=${Uri.encodeComponent(rawCity)}'
        '&postalcode=${Uri.encodeComponent(rawCap)}'
        '&format=json&addressdetails=1&limit=1');

    try {
      final response = await http
          .get(url, headers: {'User-Agent': 'PetTrackerApp_IoT_Project'});

      if (response.statusCode == 200) {
        List data = json.decode(response.body);

        if (data.isNotEmpty) {
          var addressDetails = data[0]['address'] ?? {};

          String finalStreet = addressDetails['road'] ??
              addressDetails['pedestrian'] ??
              addressDetails['square'] ??
              rawStreet;
          String finalCivic = addressDetails['house_number'] ?? rawCivic;
          String finalCity = addressDetails['city'] ??
              addressDetails['town'] ??
              addressDetails['village'] ??
              addressDetails['municipality'] ??
              rawCity;
          String finalCap = addressDetails['postcode'] ?? rawCap;

          double lat = double.parse(data[0]['lat']);
          double lon = double.parse(data[0]['lon']);
          LatLng newCenter = LatLng(lat, lon);

          bool isDuplicateLocation = savedPlaces.asMap().entries.any((e) {
            if (isUpdating && e.key == updateIndex) return false;

            final existingZone = e.value;
            LatLng existingCenter = existingZone['center'];

            String existingStreet =
                (existingZone['street'] ?? '').toString().trim().toLowerCase();
            String existingCivic =
                (existingZone['civic'] ?? '').toString().trim().toLowerCase();
            String existingCap =
                (existingZone['cap'] ?? '').toString().trim().toLowerCase();

            bool sameAddress = existingStreet == finalStreet.toLowerCase() &&
                existingCivic == finalCivic.toLowerCase() &&
                existingCap == finalCap.toLowerCase();

            if (sameAddress) {
              const Distance distance = Distance();
              final double meterDistance = distance(existingCenter, newCenter);

              if (meterDistance < 500) {
                return true;
              }
            }

            return false;
          });

          if (isDuplicateLocation) {
            return {'error': "Esiste già un'Area in questo indirizzo!"};
          }

          final body = {
            "name": rawName,
            "center_lat": newCenter.latitude,
            "center_lon": newCenter.longitude,
            "street": finalStreet,
            "civic": finalCivic,
            "city": finalCity,
            "cap": finalCap,
            "is_active": true
          };

          try {
            if (isUpdating && updateIndex != null) {
              final id = savedPlaces[updateIndex]['id'];
              final rec = await scambio.pb
                  .collection('geofences_test')
                  .update(id, body: body);
              await _caricaZoneDalDatabase(forceSelectId: rec.id);
              _activeCard.value = ActiveCard.zone;
              _mapController.move(newCenter, 18.0);

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("Area aggiornata!"),
                    backgroundColor: Colors.green));
              }
              return {
                'success': true,
                'id': rec.id,
                'name': rawName,
                'center': newCenter
              };
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("Traccia il perimetro!"),
                    backgroundColor: Colors.blueAccent));
              }
              return {
                'success': true,
                'newZoneData': body,
                'name': rawName,
                'center': newCenter
              };
            }
          } catch (e) {
            return {'error': "Errore durante il salvataggio nel database."};
          }
        } else {
          return {'error': "Indirizzo inesistente sulla mappa."};
        }
      } else {
        return {'error': "Errore di connessione al servizio mappe."};
      }
    } catch (e) {
      return {'error': "Errore di rete: $e"};
    }
  }

  Future<void> _navigateToPolygonEditor({
    String? placeId,
    Map<String, dynamic>? newZoneData,
    required String placeName,
    required LatLng center,
    List<LatLng> initialVertices = const <LatLng>[],
  }) async {
    final result = await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => PolygonEditorScreen(
                placeId: placeId,
                newZoneData: newZoneData,
                placeName: placeName,
                initialCenter: center,
                initialVertices: initialVertices)));

    if (result != null && result is String) {
      await _caricaZoneDalDatabase(forceSelectId: result);
    } else if (result == true && placeId != null) {
      await _caricaZoneDalDatabase(forceSelectId: placeId);
    } else {
      await _caricaZoneDalDatabase();
    }
  }

  void _showPlaceDialog(
      {bool isEditing = false, int? editIndex, LatLng? gpsLocation}) {
    if (isEditing && editIndex != null) {
      final place = savedPlaces[editIndex];
      _nameController.text = place['name'];
      _cityController.text = place['city'];
      _capController.text = place['cap'];
      _streetController.text = place['street'];
      _civicController.text = place['civic'];
    } else if (gpsLocation == null) {
      _nameController.clear();
      _cityController.clear();
      _capController.clear();
      _streetController.clear();
      _civicController.clear();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isLoading = false;

        String? nameError;
        String? cityError;
        String? generalError;

        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            scrollable: true,
            insetPadding: const EdgeInsets.all(15),
            titlePadding:
                const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 10),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            actionsPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            title: Text(isEditing ? "Modifica Area" : "Nuova Area",
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (generalError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(generalError!,
                          style: const TextStyle(
                              color: Colors.red,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                    ),
                  TextField(
                    controller: _nameController,
                    maxLength: 20,
                    decoration: InputDecoration(
                      labelText: "Nome luogo",
                      errorText: nameError,
                    ),
                    enabled: !isLoading,
                    onChanged: (_) => setDialogState(() => nameError = null),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _cityController,
                          decoration: InputDecoration(
                            labelText: "Città",
                            errorText: cityError,
                          ),
                          enabled: !isLoading,
                          onChanged: (_) =>
                              setDialogState(() => cityError = null),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _capController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: "CAP"),
                          enabled: !isLoading,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _streetController,
                          decoration:
                              const InputDecoration(labelText: "Via / Piazza"),
                          enabled: !isLoading,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _civicController,
                          decoration: const InputDecoration(labelText: "N°"),
                          enabled: !isLoading,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    isLoading ? null : () => Navigator.pop(dialogContext),
                child: const Text("Annulla"),
              ),
              ElevatedButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        setDialogState(() {
                          nameError = null;
                          cityError = null;
                          generalError = null;
                        });

                        final name = _nameController.text.trim();
                        final city = _cityController.text.trim();
                        final street = _streetController.text.trim();
                        final civic = _civicController.text.trim();
                        final cap = _capController.text.trim();

                        bool hasError = false;
                        if (name.isEmpty) {
                          nameError = "Inserisci un nome";
                          hasError = true;
                        }
                        if (city.isEmpty) {
                          cityError = "Inserisci la città";
                          hasError = true;
                        }

                        if (hasError) {
                          setDialogState(() {});
                          return;
                        }

                        bool isNameDuplicate =
                            savedPlaces.asMap().entries.any((e) {
                          if (isEditing && e.key == editIndex) return false;
                          String existingName = (e.value['name'] ?? '')
                              .toString()
                              .trim()
                              .toLowerCase();
                          return existingName == name.toLowerCase();
                        });

                        if (isNameDuplicate) {
                          setDialogState(() => nameError = "Nome già in uso");
                          return;
                        }

                        setDialogState(() => isLoading = true);

                        String indirizzoAttuale = "$street$civic$city$cap"
                            .toLowerCase()
                            .replaceAll(" ", "");

                        if (gpsLocation != null &&
                            !isEditing &&
                            indirizzoAttuale == _indirizzoPrecompilatoGps) {
                          bool isAddressDuplicate = savedPlaces.any((zone) {
                            String existingStreet = (zone['street'] ?? '')
                                .toString()
                                .trim()
                                .toLowerCase();
                            String existingCivic = (zone['civic'] ?? '')
                                .toString()
                                .trim()
                                .toLowerCase();
                            String existingCap = (zone['cap'] ?? '')
                                .toString()
                                .trim()
                                .toLowerCase();

                            if (existingStreet == street.toLowerCase() &&
                                existingCivic == civic.toLowerCase() &&
                                existingCap == cap.toLowerCase()) {
                              const Distance distance = Distance();
                              if (distance(zone['center'], gpsLocation) < 500)
                                return true;
                            }
                            return false;
                          });

                          if (isAddressDuplicate) {
                            setDialogState(() {
                              generalError =
                                  "Esiste già un'Area in questo indirizzo";
                              isLoading = false;
                            });
                            return;
                          }

                          final body = {
                            "name": name,
                            "center_lat": gpsLocation.latitude,
                            "center_lon": gpsLocation.longitude,
                            "street": street,
                            "civic": civic,
                            "city": city,
                            "cap": cap,
                            "is_active": true
                          };

                          if (context.mounted) {
                            Navigator.pop(dialogContext);
                            _navigateToPolygonEditor(
                                newZoneData: body,
                                placeName: name,
                                center: gpsLocation);
                          }
                        } else {
                          Map<String, dynamic> resultData =
                              await _fetchCoordinatesAndSaveOrUpdate(
                                      isUpdating: isEditing,
                                      updateIndex: editIndex) ??
                                  {};

                          if (dialogContext.mounted) {
                            if (resultData.containsKey('error')) {
                              setDialogState(() {
                                generalError = resultData['error'];
                                isLoading = false;
                              });
                            } else if (resultData['success'] == true) {
                              Navigator.pop(dialogContext);
                              if (!isEditing) {
                                _navigateToPolygonEditor(
                                    newZoneData: resultData['newZoneData'],
                                    placeName: resultData['name'],
                                    center: resultData['center']);
                              }
                            } else {
                              setDialogState(() => isLoading = false);
                            }
                          }
                        }
                      },
                child: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(isEditing ? "Aggiorna" : "Salva"),
              ),
            ],
          );
        });
      },
    );
  }

  void _confirmDeleteCurrentPlace() {
    if (selectedPlaceIndex == null) return;
    final placeName = savedPlaces[selectedPlaceIndex!]['name'];

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Elimina"),
          content: Text("Vuoi eliminare la Area '$placeName'?"),
          actions: [
            TextButton(
                child: const Text("Annulla"),
                onPressed: () => Navigator.of(context).pop()),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                final idDaEliminare = savedPlaces[selectedPlaceIndex!]['id'];

                setState(() {
                  selectedPlaceIndex = null;
                  _activeCard.value = ActiveCard.none;
                });

                try {
                  await scambio.pb
                      .collection('geofences_test')
                      .delete(idDaEliminare);
                  await _caricaZoneDalDatabase();

                  geofenceUpdateSignal.value++;

                  if (context.mounted) Navigator.of(context).pop();
                } catch (e) {}
              },
              child:
                  const Text("Elimina", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    bool hasPlaces = savedPlaces.isNotEmpty && selectedPlaceIndex != null;
    var currentPlace = hasPlaces ? savedPlaces[selectedPlaceIndex!] : null;
    bool isCurrentPlaceActive = currentPlace?['is_active'] ?? false;

    LatLng initialCenter = const LatLng(41.8719, 12.5674);
    if (_myLocation != null) {
      initialCenter = _myLocation!;
    } else if (hasPlaces) initialCenter = currentPlace!['center'];

    double screenWidth = MediaQuery.of(context).size.width;
    double scale = (screenWidth / 400).clamp(0.75, 1.1);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom:
                  hasPlaces ? 18.0 : (_myLocation != null ? 16.0 : 6.0),
              onTap: (tapPosition, point) {
                for (int i = 0; i < savedPlaces.length; i++) {
                  List<LatLng> vertices =
                      savedPlaces[i]['vertices'] as List<LatLng>? ?? [];
                  if (vertices.length >= 3 &&
                      _isPointInPolygon(point, vertices)) {
                    setState(() => selectedPlaceIndex = i);
                    _activeCard.value = ActiveCard.zone;
                    _mapController.move(savedPlaces[i]['center'], 18.0);
                    return;
                  }
                }
              },
              onPositionChanged: (MapCamera camera, bool hasGesture) {
                if (!hasGesture) return;

                if (_activeCard.value == ActiveCard.zone && hasPlaces) {
                  if (!camera.visibleBounds.contains(currentPlace!['center'])) {
                    // PULIZIA: Deseleziona l'area se l'utente sposta la mappa altrove
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      setState(() {
                        selectedPlaceIndex = null;
                      });
                      _activeCard.value = ActiveCard.none;
                    });
                  }
                } else if (_activeCard.value == ActiveCard.user &&
                    _myLocation != null) {
                  if (!camera.visibleBounds.contains(_myLocation!)) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _activeCard.value = ActiveCard.none);
                  }
                } else if (_activeCard.value == ActiveCard.pet &&
                    _petLocation != null) {
                  if (!camera.visibleBounds.contains(_petLocation!)) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _activeCard.value = ActiveCard.none);
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: isSatelliteMap
                    ? 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pet_tracker',
              ),
              PolygonLayer(
                polygons: savedPlaces
                    .where((place) =>
                        (place['vertices'] as List<LatLng>? ?? []).length >= 3)
                    .map((place) {
                  bool isActive = place['is_active'] ?? false;
                  bool isSelected =
                      hasPlaces && place['id'] == currentPlace!['id'];
                  return Polygon(
                    points: place['vertices'] as List<LatLng>,
                    color: isActive
                        ? const Color(0xFF00C6B8)
                            .withOpacity(isSelected ? 0.4 : 0.15)
                        : Colors.grey.withOpacity(isSelected ? 0.4 : 0.15),
                    borderColor:
                        isActive ? const Color(0xFF00C6B8) : Colors.grey,
                    borderStrokeWidth: isSelected ? 3 : 1.5,
                  );
                }).toList(),
              ),
              if (_myLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _myLocation!,
                      width: 60,
                      height: 60,
                      child: GestureDetector(
                        onTap: () {
                          setState(() => selectedPlaceIndex = null);
                          _activeCard.value = ActiveCard.user;
                          _resolveAddress(_myLocation!, false);
                          _mapController.move(_myLocation!, 18.0);
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.blue.withOpacity(0.3))),
                            Container(
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.blue,
                                    border: Border.all(
                                        color: Colors.white, width: 2))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              if (_petLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                        point: _petLocation!,
                        width: 60,
                        height: 60,
                        child: GestureDetector(
                          onTap: () {
                            setState(() => selectedPlaceIndex = null);
                            _activeCard.value = ActiveCard.pet;
                            _resolveAddress(_petLocation!, true);
                            _mapController.move(_petLocation!, 18.0);
                          },
                          child: const Icon(Icons.pets,
                              color: Colors.orange, size: 30),
                        )),
                  ],
                ),
            ],
          ),
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(15.0 * scale),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: hasPlaces || savedPlaces.isNotEmpty
                          ? Container(
                              padding:
                                  EdgeInsets.symmetric(horizontal: 10 * scale),
                              height: 45 * scale,
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius:
                                      BorderRadius.circular(15 * scale),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black12, blurRadius: 10)
                                  ]),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  isExpanded: true,
                                  menuMaxHeight: 240,
                                  value: selectedPlaceIndex,
                                  hint: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text("Seleziona Area...",
                                        style: TextStyle(
                                            color: Colors.black54,
                                            fontSize: 15 * scale,
                                            fontWeight: FontWeight.w600)),
                                  ),
                                  selectedItemBuilder: (BuildContext context) {
                                    return savedPlaces.map<Widget>((item) {
                                      return Align(
                                        alignment: Alignment.centerLeft,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text("Area Sicura",
                                              style: TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 15 * scale,
                                                  fontWeight: FontWeight.w600)),
                                        ),
                                      );
                                    }).toList();
                                  },
                                  style: TextStyle(
                                      color: Colors.black87,
                                      fontSize: 15 * scale,
                                      fontWeight: FontWeight.w600),
                                  items: List.generate(savedPlaces.length, (i) {
                                    bool isActiveZone =
                                        savedPlaces[i]['is_active'] ?? false;
                                    return DropdownMenuItem(
                                      value: i,
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: isActiveZone
                                                  ? Colors.green
                                                  : Colors.orange,
                                              boxShadow: [
                                                if (isActiveZone)
                                                  BoxShadow(
                                                      color: Colors.green
                                                          .withOpacity(0.4),
                                                      blurRadius: 4,
                                                      spreadRadius: 1)
                                              ],
                                            ),
                                          ),
                                          SizedBox(width: 10 * scale),
                                          Expanded(
                                              child: Text(
                                                  savedPlaces[i]['name'],
                                                  style: TextStyle(
                                                      fontSize: 14 * scale,
                                                      color: isActiveZone
                                                          ? Colors.black87
                                                          : Colors.black45,
                                                      fontWeight: isActiveZone
                                                          ? FontWeight.w600
                                                          : FontWeight.normal),
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                        ],
                                      ),
                                    );
                                  }),
                                  onChanged: (val) {
                                    setState(() => selectedPlaceIndex = val!);
                                    _activeCard.value = ActiveCard.zone;
                                    _mapController.move(
                                        savedPlaces[val!]['center'], 18.0);
                                  },
                                ),
                              ),
                            )
                          : Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 15 * scale, vertical: 10 * scale),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius:
                                      BorderRadius.circular(15 * scale)),
                              child: Text("Nessuna Area",
                                  style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 14 * scale)),
                            ),
                    ),
                    SizedBox(width: 15 * scale),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton.small(
                          heroTag: "addPlace",
                          onPressed: _promptAddLocation,
                          backgroundColor: const Color(0xFF00C6B8),
                          child: const Icon(Icons.add, color: Colors.white),
                        ),
                        SizedBox(height: 10 * scale),
                        FloatingActionButton.small(
                          heroTag: "locatePet",
                          onPressed: () {
                            if (_petLocation != null) {
                              setState(() => selectedPlaceIndex = null);
                              _mapController.move(_petLocation!, 18.0);
                              _activeCard.value = ActiveCard.pet;
                              _resolveAddress(_petLocation!, true);
                            }
                          },
                          backgroundColor: Colors.white,
                          child: const Icon(Icons.pets, color: Colors.orange),
                        ),
                        SizedBox(height: 10 * scale),
                        FloatingActionButton.small(
                          heroTag: "locateMe",
                          onPressed: () async {
                            if (_myLocation == null) await _determinePosition();
                            if (_myLocation != null) {
                              setState(() => selectedPlaceIndex = null);
                              _mapController.move(_myLocation!, 18.0);
                              _activeCard.value = ActiveCard.user;
                              _resolveAddress(_myLocation!, false);
                            }
                          },
                          backgroundColor: Colors.white,
                          child: const Icon(Icons.smartphone,
                              color: Colors.blueAccent),
                        ),
                        SizedBox(height: 10 * scale),
                        FloatingActionButton.small(
                          heroTag: "mapSwitch",
                          onPressed: () =>
                              setState(() => isSatelliteMap = !isSatelliteMap),
                          backgroundColor: Colors.white,
                          child: Icon(
                              isSatelliteMap ? Icons.map : Icons.satellite_alt,
                              color: const Color(0xFF00C6B8)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ValueListenableBuilder<ActiveCard>(
              valueListenable: _activeCard,
              builder: (context, activeCard, child) {
                if (activeCard == ActiveCard.none)
                  return const SizedBox.shrink();

                if (activeCard == ActiveCard.zone && hasPlaces) {
                  return Container(
                    padding: EdgeInsets.all(15 * scale),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20 * scale),
                      boxShadow: const [
                        BoxShadow(color: Colors.black12, blurRadius: 10)
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            Align(
                              alignment: Alignment.center,
                              child: Text(currentPlace!['name'],
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18 * scale)),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: InkWell(
                                  onTap: () {
                                    // PULIZIA: Deseleziona la zona se clicchi sulla "X" della sua card
                                    setState(() {
                                      selectedPlaceIndex = null;
                                    });
                                    _activeCard.value = ActiveCard.none;
                                  },
                                  child: Icon(Icons.close,
                                      color: Colors.black45, size: 24 * scale)),
                            )
                          ],
                        ),
                        SizedBox(height: 5 * scale),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            "${currentPlace['city']} (${currentPlace['cap']}) - ${currentPlace['street']}, ${currentPlace['civic']}",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.black45, fontSize: 13 * scale),
                          ),
                        ),
                        const Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Expanded(
                                child: InkWell(
                                    onTap: () async {
                                      _navigateToPolygonEditor(
                                          placeId: currentPlace['id'],
                                          placeName: currentPlace['name'],
                                          center: currentPlace['center'],
                                          initialVertices:
                                              currentPlace['vertices']);
                                    },
                                    child: _buildSmallAction(
                                        Icons.draw, "Disegna",
                                        color: Colors.purple, scale: scale))),
                            Expanded(
                                child: InkWell(
                                    onTap: () => _showPlaceDialog(
                                        isEditing: true,
                                        editIndex: selectedPlaceIndex),
                                    child: _buildSmallAction(
                                        Icons.edit, "Modifica",
                                        color: Colors.blueAccent,
                                        scale: scale))),
                            Expanded(
                                child: InkWell(
                                    onTap: () => _toggleZoneActiveStatus(
                                        currentPlace['id'],
                                        isCurrentPlaceActive),
                                    child: _buildSmallAction(
                                        isCurrentPlaceActive
                                            ? Icons.notifications_off
                                            : Icons.notifications_active,
                                        isCurrentPlaceActive
                                            ? "Disattiva"
                                            : "Attiva",
                                        color: isCurrentPlaceActive
                                            ? Colors.orange
                                            : Colors.green,
                                        scale: scale))),
                            Expanded(
                                child: InkWell(
                                    onTap: _confirmDeleteCurrentPlace,
                                    child: _buildSmallAction(
                                        Icons.delete_outline, "Elimina",
                                        color: Colors.red, scale: scale))),
                          ],
                        )
                      ],
                    ),
                  );
                }

                if (activeCard == ActiveCard.user ||
                    activeCard == ActiveCard.pet) {
                  bool isPet = activeCard == ActiveCard.pet;
                  return Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 20 * scale, vertical: 15 * scale),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20 * scale),
                      boxShadow: const [
                        BoxShadow(color: Colors.black12, blurRadius: 10)
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Icon(isPet ? Icons.pets : Icons.person,
                                  color:
                                      isPet ? Colors.orange : Colors.blueAccent,
                                  size: 28 * scale),
                            ),
                            Align(
                              alignment: Alignment.center,
                              child: Text(
                                  isPet
                                      ? "Posizione Animale"
                                      : "La Mia Posizione",
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16 * scale)),
                            ),
                            Align(
                                alignment: Alignment.centerRight,
                                child: InkWell(
                                    onTap: () =>
                                        _activeCard.value = ActiveCard.none,
                                    child: Icon(Icons.close,
                                        color: Colors.black45,
                                        size: 24 * scale)))
                          ],
                        ),
                        const Divider(),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 5 * scale),
                            child: Text(
                              isPet ? _petAddress : _userAddress,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.black45, fontSize: 13 * scale),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallAction(IconData icon, String label,
      {Color color = Colors.black45, required double scale}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.0 * scale, horizontal: 2.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24 * scale),
          SizedBox(height: 4 * scale),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label,
                style: TextStyle(
                    fontSize: 11 * scale,
                    color: color,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
