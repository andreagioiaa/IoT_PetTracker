import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'scambio.dart' as scambio;

class GeofencingScreen extends StatefulWidget {
  const GeofencingScreen({Key? key}) : super(key: key);

  @override
  State<GeofencingScreen> createState() => _GeofencingScreenState();
}

class _GeofencingScreenState extends State<GeofencingScreen> {
  List<Map<String, dynamic>> savedPlaces = [];
  bool isLoading = true;

  LatLng? _petLocation;
  StreamSubscription? _streamSubscription; // <-- 1. Dichiariamo l'antenna

  @override
  void initState() {
    super.initState();
    _caricaZoneDalDatabase();

    // 2. ACCENDIAMO L'ANTENNA (si muoverà da sola ad ogni pacchetto!)
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

    // 3. Scarichiamo la foto iniziale
    _scaricaPosizioneInizialeAnimale();
    _determinePosition();
  }

  @override
  void dispose() {
    _isPlaceInView.dispose();
    _streamSubscription
        ?.cancel(); // <-- 4. Spegniamo l'antenna quando chiudiamo la mappa
    super.dispose();
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

  Future<void> _caricaZoneDalDatabase() async {
    setState(() => isLoading = true);
    if (!scambio.isReady) await scambio.autenticazione();

    try {
      final records =
          await scambio.pb.collection('geofences_test').getFullList();
      final List<Map<String, dynamic>> nuoveZone = records.map((res) {
        return {
          "id": res.id,
          "name": res.getStringValue('name'),
          "street": res.getStringValue('street'),
          "civic": res.getStringValue('civic'),
          "city": res.getStringValue('city'),
          "cap": res.getStringValue('cap'),
          "center": LatLng(res.getDoubleValue('center_lat'),
              res.getDoubleValue('center_lon')),
          "radius": res.getDoubleValue('radius'),
          "is_active": res.getBoolValue('is_active'),
        };
      }).toList();

      setState(() {
        savedPlaces = nuoveZone;
        isLoading = false;

        // --- CORREZIONE RANGE ERROR ---
        if (savedPlaces.isEmpty) {
          selectedPlaceIndex =
              null; // Se non c'è nessuna zona, togliamo la selezione
        } else if (selectedPlaceIndex == null ||
            selectedPlaceIndex! >= savedPlaces.length) {
          // Se l'indice è diventato fuori dai limiti (es. era 5 ma la lista ora ha 5 elementi, da 0 a 4)
          // torna in automatico alla prima zona (0)
          selectedPlaceIndex = 0;
        }
        // --------------------------------
      });
    } catch (e) {
      debugPrint("Errore caricamento: $e");
      setState(() => isLoading = false);
    }
  }

  Future<void> _toggleZoneActiveStatus(String id, bool currentStatus) async {
    try {
      // Inverte lo stato (se era true diventa false, e viceversa)
      final newStatus = !currentStatus;

      await scambio.pb.collection('geofences_test').update(id, body: {
        "is_active": newStatus,
      });

      await _caricaZoneDalDatabase(); // Ricarica i dati per aggiornare la UI

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newStatus ? "Zona attivata." : "Zona disattivata."),
          backgroundColor: newStatus ? Colors.green : Colors.orange,
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      debugPrint("Errore attivazione zona: $e");
    }
  }

  int? selectedPlaceIndex = 0;
  final MapController _mapController = MapController();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _streetController = TextEditingController();
  final TextEditingController _civicController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  final TextEditingController _capController = TextEditingController();

  double _tempRadius = 30.0;
  bool isSatelliteMap = false;
  LatLng? _myLocation;

  final ValueNotifier<bool> _isPlaceInView = ValueNotifier<bool>(true);

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

        _mapController.move(_myLocation!, 16.0);
      }
    } catch (e) {
      debugPrint("Errore geolocalizzazione: $e");
    }
  }

  Future<void> _promptAddLocation() async {
    if (_myLocation == null) {
      _showPlaceDialog(isEditing: false);
      return;
    }

    bool? useCurrentLocation = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Nuova Zona Sicura"),
        content: const Text(
            "Vuoi creare una zona basata esattamente sulla tua posizione attuale?"),
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
    _tempRadius = 30.0;

    _showPlaceDialog(isEditing: false, gpsLocation: _myLocation);
  }

  Future<bool> _fetchCoordinatesAndSaveOrUpdate(double chosenRadius,
      {bool isUpdating = false, int? updateIndex}) async {
    final String name = _nameController.text.trim();
    final String street = _streetController.text.trim();
    final String civic = _civicController.text.trim();
    final String city = _cityController.text.trim();
    final String cap = _capController.text.trim();

    final url = Uri.parse('https://nominatim.openstreetmap.org/search?'
        'street=${Uri.encodeComponent("$civic $street")}'
        '&city=${Uri.encodeComponent(city)}'
        '&postalcode=${Uri.encodeComponent(cap)}'
        '&format=json'
        '&addressdetails=1'
        '&limit=1');

    try {
      final response = await http
          .get(url, headers: {'User-Agent': 'PetTrackerApp_IoT_Project'});

      if (response.statusCode == 200) {
        List data = json.decode(response.body);

        if (data.isNotEmpty) {
          var addressDetails = data[0]['address'];
          String? returnedCap =
              addressDetails != null ? addressDetails['postcode'] : null;

          if (returnedCap != null && !returnedCap.contains(cap)) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      "Attenzione: Il CAP inserito ($cap) non corrisponde (CAP reale: $returnedCap)."),
                  backgroundColor: Colors.redAccent,
                  duration: const Duration(seconds: 4)),
            );
            return false;
          }

          double lat = double.parse(data[0]['lat']);
          double lon = double.parse(data[0]['lon']);
          LatLng newCenter = LatLng(lat, lon);

          final body = {
            "name": name,
            "center_lat": newCenter.latitude,
            "center_lon": newCenter.longitude,
            "radius": chosenRadius,
            "street": street,
            "civic": civic,
            "city": city,
            "cap": cap,
            "is_active": true,
          };

          try {
            if (isUpdating && updateIndex != null) {
              final id = savedPlaces[updateIndex]['id'];
              await scambio.pb
                  .collection('geofences_test')
                  .update(id, body: body);
            } else {
              await scambio.pb.collection('geofences_test').create(body: body);
            }
            await _caricaZoneDalDatabase();
          } catch (e) {
            debugPrint("Errore salvataggio DB: $e");
          }

          _isPlaceInView.value = true;
          _mapController.move(newCenter, 18.0);

          _nameController.clear();
          _streetController.clear();
          _civicController.clear();
          _cityController.clear();
          _capController.clear();
          _tempRadius = 30.0;

          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(isUpdating
                  ? "Zona '$name' aggiornata!"
                  : "Zona '$name' creata!"),
              backgroundColor: Colors.green));
          return true;
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Errore: Indirizzo inesistente."),
              backgroundColor: Colors.red));
          return false;
        }
      } else {
        return false;
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Errore di rete: $e"), backgroundColor: Colors.red));
      return false;
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
      _tempRadius = place['radius'];
    } else if (gpsLocation == null) {
      _nameController.clear();
      _cityController.clear();
      _capController.clear();
      _streetController.clear();
      _civicController.clear();
      _tempRadius = 30.0;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isLoading = false;

        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title:
                Text(isEditing ? "Modifica Zona Sicura" : "Nuova Zona Sicura"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                      controller: _nameController,
                      maxLength: 15,
                      decoration: const InputDecoration(
                          labelText: "Nome luogo", hintText: "Es. Casa"),
                      enabled: !isLoading),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                          flex: 2,
                          child: TextField(
                              controller: _cityController,
                              decoration:
                                  const InputDecoration(labelText: "Città"),
                              enabled: !isLoading)),
                      const SizedBox(width: 10),
                      Expanded(
                          flex: 1,
                          child: TextField(
                              controller: _capController,
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: "CAP"),
                              enabled: !isLoading)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                          flex: 3,
                          child: TextField(
                              controller: _streetController,
                              decoration: const InputDecoration(
                                  labelText: "Via / Piazza",
                                  hintText: "Opzionale con GPS"),
                              enabled: !isLoading)),
                      const SizedBox(width: 10),
                      Expanded(
                          flex: 1,
                          child: TextField(
                              controller: _civicController,
                              decoration: const InputDecoration(
                                  labelText: "N°", hintText: "SNC"),
                              enabled: !isLoading)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Align(
                      alignment: Alignment.centerLeft,
                      child: Text("Raggio area sicura:",
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _tempRadius,
                          min: 10.0,
                          max: 50.0,
                          divisions: 8,
                          activeColor: const Color(0xFF00C6B8),
                          label: "${_tempRadius.round()} metri",
                          onChanged: isLoading
                              ? null
                              : (double value) {
                                  setDialogState(() {
                                    _tempRadius = value;
                                  });
                                },
                        ),
                      ),
                      Text("${_tempRadius.round()} m",
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed:
                      isLoading ? null : () => Navigator.pop(dialogContext),
                  child: const Text("Annulla")),
              ElevatedButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        final name = _nameController.text.trim();
                        final street = _streetController.text.trim();
                        final civic = _civicController.text.trim();
                        final city = _cityController.text.trim();
                        final cap = _capController.text.trim();

                        if (name.isEmpty || city.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      "Inserisci almeno Nome Luogo e Città."),
                                  backgroundColor: Colors.orange));
                          return;
                        }

                        bool nameExists = savedPlaces.asMap().entries.any((e) =>
                            e.key != editIndex &&
                            e.value['name'].toString().toLowerCase() ==
                                name.toLowerCase());
                        if (nameExists) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Nome già in uso."),
                                  backgroundColor: Colors.redAccent));
                          return;
                        }

                        setDialogState(() {
                          isLoading = true;
                        });

                        if (gpsLocation != null && !isEditing) {
                          final body = {
                            "name": name,
                            "center_lat": gpsLocation.latitude,
                            "center_lon": gpsLocation.longitude,
                            "radius": _tempRadius,
                            "street":
                                street.isEmpty ? "Via Sconosciuta" : street,
                            "civic": civic.isEmpty ? "SNC" : civic,
                            "city": city,
                            "cap": cap.isEmpty ? "00000" : cap,
                            "is_active": true,
                          };

                          try {
                            await scambio.pb
                                .collection('geofences_test')
                                .create(body: body);
                            await _caricaZoneDalDatabase();

                            _isPlaceInView.value = true;
                            _mapController.move(gpsLocation, 18.0);

                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    "Zona '$name' creata sulla tua posizione!"),
                                backgroundColor: Colors.green));

                            if (context.mounted) Navigator.pop(dialogContext);
                          } catch (e) {
                            debugPrint("Errore creazione GPS: $e");
                            setDialogState(() => isLoading = false);
                          }
                        } else {
                          if (street.isEmpty || civic.isEmpty || cap.isEmpty) {
                            setDialogState(() {
                              isLoading = false;
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        "Per la ricerca manuale compila Via, N° e CAP."),
                                    backgroundColor: Colors.orange));
                            return;
                          }

                          bool success = await _fetchCoordinatesAndSaveOrUpdate(
                              _tempRadius,
                              isUpdating: isEditing,
                              updateIndex: editIndex);

                          if (success && dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          } else if (dialogContext.mounted) {
                            setDialogState(() {
                              isLoading = false;
                            });
                          }
                        }
                      },
                child: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(isEditing ? "Aggiorna" : "Salva Zona"),
              ),
            ],
          );
        });
      },
    );
  }

  void _confirmDeleteCurrentPlace() {
    if (selectedPlaceIndex == null) return;

    final placeToDelete = savedPlaces[selectedPlaceIndex!];
    final placeName = placeToDelete['name'];

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Conferma Eliminazione"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.black87, fontSize: 16),
                  children: [
                    const TextSpan(
                        text: "Sei sicuro di voler eliminare la zona "),
                    TextSpan(
                        text: "'$placeName'",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.red)),
                    const TextSpan(text: "?"),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Dettagli zona:",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.black54)),
                    const SizedBox(height: 5),
                    Text(
                        "Indirizzo: ${placeToDelete['street']}, ${placeToDelete['civic']}",
                        style: const TextStyle(fontSize: 14)),
                    Text(
                        "Città: ${placeToDelete['city']} (${placeToDelete['cap']})",
                        style: const TextStyle(fontSize: 14)),
                    Text("Raggio: ${placeToDelete['radius'].round()} metri",
                        style: const TextStyle(fontSize: 14)),
                  ],
                ),
              )
            ],
          ),
          actions: [
            TextButton(
              child:
                  const Text("Annulla", style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                final idDaEliminare = savedPlaces[selectedPlaceIndex!]['id'];

                try {
                  await scambio.pb
                      .collection('geofences_test')
                      .delete(idDaEliminare);
                  await _caricaZoneDalDatabase();

                  if (context.mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text("Zona '$placeName' eliminata."),
                          backgroundColor: Colors.black87),
                    );
                  }
                } catch (e) {
                  debugPrint("Errore eliminazione: $e");
                }
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

    // NUOVO: Controlla se la zona selezionata è attiva
    bool isCurrentPlaceActive = currentPlace?['is_active'] ?? false;

    LatLng initialCenter = const LatLng(41.8719, 12.5674);
    if (_myLocation != null) {
      initialCenter = _myLocation!;
    } else if (hasPlaces) {
      initialCenter = currentPlace!['center'];
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom:
                  hasPlaces ? 18.0 : (_myLocation != null ? 16.0 : 6.0),
              onPositionChanged: (MapPosition position, bool hasGesture) {
                if (hasPlaces && position.bounds != null) {
                  final placeCenter =
                      savedPlaces[selectedPlaceIndex!]['center'] as LatLng;
                  final isVisible = position.bounds!.contains(placeCenter);

                  if (_isPlaceInView.value != isVisible) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _isPlaceInView.value = isVisible;
                    });
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
              if (hasPlaces)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: currentPlace!['center'],
                      radius: currentPlace['radius'],
                      useRadiusInMeter: true,
                      // NUOVO: Se non è attiva, coloriamo il recinto di grigio
                      color: isCurrentPlaceActive
                          ? const Color(0xFF00C6B8).withOpacity(0.3)
                          : Colors.grey.withOpacity(0.4),
                      borderColor: isCurrentPlaceActive
                          ? const Color(0xFF00C6B8)
                          : Colors.grey,
                      borderStrokeWidth: 3,
                    ),
                  ],
                ),
              // Marker per la tua posizione
              if (_myLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _myLocation!,
                      width: 40,
                      height: 40,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue.withOpacity(0.3),
                            ),
                          ),
                          Container(
                            width: 15,
                            height: 15,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

              // Marker dedicato per il CANE (Arancione)
              if (_petLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _petLocation!,
                      width: 50,
                      height: 50,
                      child: const Icon(
                        Icons.pets,
                        color: Colors.orange,
                        size: 30,
                      ),
                    ),
                  ],
                ),

              // Marker per il centro del recinto (Rosso o Grigio scuro)
              if (hasPlaces)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentPlace!['center'],
                      width: 30,
                      height: 30,
                      child: Icon(Icons.location_on,
                          color: isCurrentPlaceActive
                              ? Colors.red
                              : Colors.grey.shade700,
                          size: 30),
                    ),
                  ],
                ),
            ],
          ),
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(15.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: hasPlaces
                          ? Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 15),
                              height: 45,
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(15),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black12, blurRadius: 10)
                                  ]),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  isExpanded: true,

                                  // --- LA MAGIA PER I 5 ELEMENTI ---
                                  menuMaxHeight: 240, // 48px * 5 elementi
                                  itemHeight:
                                      48, // Fissa l'altezza di ogni riga
                                  // ---------------------------------

                                  value: selectedPlaceIndex,
                                  style: const TextStyle(
                                    color: Colors.black87,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  items: List.generate(savedPlaces.length, (i) {
                                    bool isActiveZone =
                                        savedPlaces[i]['is_active'] ?? false;
                                    return DropdownMenuItem(
                                        value: i,
                                        // NUOVO: Aggiunta la spunta verde nel Dropdown se la zona è attiva
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                savedPlaces[i]['name'],
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (isActiveZone) ...[
                                              const SizedBox(width: 8),
                                              const Icon(Icons.check_circle,
                                                  color: Colors.green,
                                                  size: 16),
                                            ]
                                          ],
                                        ));
                                  }),
                                  onChanged: (val) {
                                    setState(() {
                                      selectedPlaceIndex = val!;
                                    });
                                    _isPlaceInView.value = true;
                                    _mapController.move(
                                        savedPlaces[val!]['center'], 18.0);
                                  },
                                ),
                              ),
                            )
                          : Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 15, vertical: 10),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(15)),
                              child: const Text("Nessuna zona",
                                  style: TextStyle(color: Colors.grey)),
                            ),
                    ),
                    const SizedBox(width: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton.small(
                          heroTag: "locatePet",
                          onPressed: () async {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text("Ricerca posizione animale..."),
                                    duration: Duration(seconds: 1)));

                            await _scaricaPosizioneInizialeAnimale();

                            if (_petLocation != null) {
                              _mapController.move(_petLocation!, 18.0);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content:
                                          Text("Posizione non disponibile.")));
                            }
                          },
                          backgroundColor: Colors.white,
                          child: const Icon(Icons.pets, color: Colors.orange),
                        ),
                        const SizedBox(width: 8),
                        FloatingActionButton.small(
                          heroTag: "locateMe",
                          onPressed: () async {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text("Ricerca posizione in corso..."),
                                    duration: Duration(seconds: 1)));
                            await _determinePosition();
                          },
                          backgroundColor: Colors.white,
                          child: const Icon(Icons.smartphone,
                              color: Colors.blueAccent),
                        ),
                        const SizedBox(width: 8),
                        FloatingActionButton.small(
                          heroTag: "mapSwitch",
                          onPressed: () {
                            setState(() {
                              isSatelliteMap = !isSatelliteMap;
                            });
                          },
                          backgroundColor: Colors.white,
                          child: Icon(
                              isSatelliteMap ? Icons.map : Icons.satellite_alt,
                              color: const Color(0xFF00C6B8)),
                        ),
                        const SizedBox(width: 8),
                        FloatingActionButton.small(
                          heroTag: "addPlace",
                          onPressed: _promptAddLocation,
                          backgroundColor: const Color(0xFF00C6B8),
                          child: const Icon(Icons.add, color: Colors.white),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (hasPlaces)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: ValueListenableBuilder<bool>(
                valueListenable: _isPlaceInView,
                builder: (context, isVisible, child) {
                  if (!isVisible) return const SizedBox.shrink();

                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [
                        BoxShadow(color: Colors.black12, blurRadius: 10)
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentPlace!['name'],
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          "${currentPlace['city']} (${currentPlace['cap']}) - ${currentPlace['street']}, ${currentPlace['civic']}",
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.black45, fontSize: 13),
                        ),
                        const Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            InkWell(
                                onTap: () => _showPlaceDialog(
                                    isEditing: true,
                                    editIndex: selectedPlaceIndex),
                                child: _buildSmallAction(Icons.edit, "Modifica",
                                    color: Colors.blueAccent)),
                            InkWell(
                                onTap: () => _toggleZoneActiveStatus(
                                    currentPlace['id'], isCurrentPlaceActive),
                                child: _buildSmallAction(
                                    isCurrentPlaceActive
                                        ? Icons.notifications_off
                                        : Icons.notifications_active,
                                    isCurrentPlaceActive
                                        ? "Disattiva"
                                        : "Attiva",
                                    color: isCurrentPlaceActive
                                        ? Colors.orange
                                        : Colors.green)),
                            InkWell(
                                onTap: _confirmDeleteCurrentPlace,
                                child: _buildSmallAction(
                                    Icons.delete_outline, "Elimina",
                                    color: Colors.red)),
                          ],
                        )
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSmallAction(IconData icon, String label,
      {Color color = Colors.black45}) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
