import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart'; 

class GeofencingScreen extends StatefulWidget {
  const GeofencingScreen({Key? key}) : super(key: key);

  @override
  State<GeofencingScreen> createState() => _GeofencingScreenState();
}

class _GeofencingScreenState extends State<GeofencingScreen> {
  List<Map<String, dynamic>> savedPlaces = [
    {
      "name": "Uniud Polo Rizzi",
      "street": "via delle scienze",
      "civic": "206",
      "city": "udine",
      "cap": "33100",
      "center": const LatLng(46.0804, 13.2126),
      "radius": 50.0, 
    }
  ];

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
  
  // NUOVA VARIABILE: Controlla se il luogo selezionato è attualmente visibile nello schermo
  bool _isPlaceInView = true;

  @override
  void initState() {
    super.initState();
    _determinePosition(); 
  }

  Future<void> _determinePosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('Servizi GPS disabilitati');

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) throw Exception('Permessi negati');
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Impossibile trovare la posizione. Controlla il GPS o i permessi."), 
            backgroundColor: Colors.orange
          ),
        );
      }
    }
  }

  Future<bool> _fetchCoordinatesAndSaveOrUpdate(double chosenRadius, {bool isUpdating = false, int? updateIndex}) async {
    final String name = _nameController.text.trim();
    final String street = _streetController.text.trim();
    final String civic = _civicController.text.trim();
    final String city = _cityController.text.trim();
    final String cap = _capController.text.trim();

    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search?'
      'street=${Uri.encodeComponent("$civic $street")}'
      '&city=${Uri.encodeComponent(city)}'
      '&postalcode=${Uri.encodeComponent(cap)}'
      '&format=json'
      '&addressdetails=1' 
      '&limit=1'
    );

    try {
      final response = await http.get(url, headers: {'User-Agent': 'PetTrackerApp_IoT_Project'});

      if (response.statusCode == 200) {
        List data = json.decode(response.body);
        
        if (data.isNotEmpty) {
          var addressDetails = data[0]['address'];
          String? returnedCap = addressDetails != null ? addressDetails['postcode'] : null;

          if (returnedCap != null && !returnedCap.contains(cap)) {
             ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Attenzione: Il CAP inserito ($cap) non corrisponde (CAP reale: $returnedCap)."), 
                backgroundColor: Colors.redAccent,
                duration: const Duration(seconds: 4),
              ),
            );
            return false;
          }

          double lat = double.parse(data[0]['lat']);
          double lon = double.parse(data[0]['lon']);
          LatLng newCenter = LatLng(lat, lon);

          final newPlaceData = {
            "name": name,
            "street": street,
            "civic": civic,
            "city": city,
            "cap": cap,
            "center": newCenter,
            "radius": chosenRadius,
          };

          setState(() {
            if (isUpdating && updateIndex != null) {
              savedPlaces[updateIndex] = newPlaceData;
              selectedPlaceIndex = updateIndex;
            } else {
              savedPlaces.add(newPlaceData);
              selectedPlaceIndex = savedPlaces.length - 1;
            }
            _isPlaceInView = true; // Mostra subito il pannello quando creiamo/aggiorniamo
            _mapController.move(newCenter, 18.0); 
          });

          _nameController.clear();
          _streetController.clear();
          _civicController.clear();
          _cityController.clear();
          _capController.clear();
          _tempRadius = 30.0; 

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isUpdating ? "Zona '$name' aggiornata!" : "Zona '$name' creata!"), 
              backgroundColor: Colors.green
            ),
          );
          return true;
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Errore: Indirizzo inesistente."), backgroundColor: Colors.red),
          );
          return false;
        }
      } else {
        return false;
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Errore di rete: $e"), backgroundColor: Colors.red),
      );
      return false;
    }
  }

  void _showPlaceDialog({bool isEditing = false, int? editIndex}) {
    if (isEditing && editIndex != null) {
      final place = savedPlaces[editIndex];
      _nameController.text = place['name'];
      _cityController.text = place['city'];
      _capController.text = place['cap'];
      _streetController.text = place['street'];
      _civicController.text = place['civic'];
      _tempRadius = place['radius'];
    } else {
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

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(isEditing ? "Modifica Zona Sicura" : "Nuova Zona Sicura"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(labelText: "Nome luogo", hintText: "Es. Casa Mia"),
                        enabled: !isLoading),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(flex: 2, child: TextField(controller: _cityController, decoration: const InputDecoration(labelText: "Città"), enabled: !isLoading)),
                        const SizedBox(width: 10),
                        Expanded(flex: 1, child: TextField(controller: _capController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "CAP"), enabled: !isLoading)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(flex: 3, child: TextField(controller: _streetController, decoration: const InputDecoration(labelText: "Via / Piazza", hintText: "Es. Via Roma"), enabled: !isLoading)),
                        const SizedBox(width: 10),
                        Expanded(flex: 1, child: TextField(controller: _civicController, decoration: const InputDecoration(labelText: "N°", hintText: "Civico"), enabled: !isLoading)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Align(alignment: Alignment.centerLeft, child: Text("Raggio area sicura:", style: TextStyle(fontWeight: FontWeight.bold))),
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
                            onChanged: isLoading ? null : (double value) { setDialogState(() { _tempRadius = value; }); },
                          ),
                        ),
                        Text("${_tempRadius.round()} m", style: const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: isLoading ? null : () => Navigator.pop(dialogContext),
                    child: const Text("Annulla")),
                ElevatedButton(
                  onPressed: isLoading ? null : () async {
                    final name = _nameController.text.trim();
                    final street = _streetController.text.trim().toLowerCase();
                    final civic = _civicController.text.trim().toLowerCase();
                    final city = _cityController.text.trim().toLowerCase();
                    final cap = _capController.text.trim();
                    
                    if (name.isEmpty || city.isEmpty || street.isEmpty || civic.isEmpty || cap.isEmpty) {
                       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Compila tutti i campi"), backgroundColor: Colors.orange));
                       return;
                    }

                    bool nameExists = savedPlaces.asMap().entries.any((entry) => 
                      entry.key != editIndex && entry.value['name'].toString().toLowerCase() == name.toLowerCase()
                    );
                    if (nameExists) {
                       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Nome già in uso."), backgroundColor: Colors.redAccent));
                       return; 
                    }

                    bool addressExists = savedPlaces.asMap().entries.any((entry) => 
                      entry.key != editIndex && 
                      entry.value['street'].toString().toLowerCase() == street && 
                      entry.value['civic'].toString().toLowerCase() == civic && 
                      entry.value['city'].toString().toLowerCase() == city && 
                      entry.value['cap'].toString() == cap
                    );
                    if (addressExists) {
                       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Indirizzo già configurato."), backgroundColor: Colors.redAccent));
                       return;
                    }

                    setDialogState(() { isLoading = true; });

                    bool success = await _fetchCoordinatesAndSaveOrUpdate(
                      _tempRadius, 
                      isUpdating: isEditing, 
                      updateIndex: editIndex
                    );

                    if (success && dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    } else if (dialogContext.mounted) {
                      setDialogState(() { isLoading = false; });
                    }
                  },
                  child: isLoading 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(isEditing ? "Aggiorna" : "Cerca e Salva"),
                ),
              ],
            );
          }
        );
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
                    const TextSpan(text: "Sei sicuro di voler eliminare la zona "),
                    TextSpan(text: "'$placeName'", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
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
                  borderRadius: BorderRadius.circular(8)
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Dettagli zona:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black54)),
                    const SizedBox(height: 5),
                    Text("Indirizzo: ${placeToDelete['street']}, ${placeToDelete['civic']}", style: const TextStyle(fontSize: 14)),
                    Text("Città: ${placeToDelete['city']} (${placeToDelete['cap']})", style: const TextStyle(fontSize: 14)),
                    Text("Raggio: ${placeToDelete['radius'].round()} metri", style: const TextStyle(fontSize: 14)),
                  ],
                ),
              )
            ],
          ),
          actions: [
            TextButton(
              child: const Text("Annulla", style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                setState(() {
                  savedPlaces.removeAt(selectedPlaceIndex!);
                  if (savedPlaces.isEmpty) {
                    selectedPlaceIndex = null;
                    _isPlaceInView = false;
                  } else {
                    selectedPlaceIndex = 0;
                    _isPlaceInView = true;
                    _mapController.move(savedPlaces[0]['center'], 18.0);
                  }
                });
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Zona '$placeName' eliminata."), backgroundColor: Colors.black87),
                );
              },
              child: const Text("Elimina", style: TextStyle(color: Colors.white)),
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

    LatLng initialCenter = const LatLng(41.8719, 12.5674);
    if (hasPlaces) {
      initialCenter = currentPlace!['center'];
    } else if (_myLocation != null) {
      initialCenter = _myLocation!;
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: hasPlaces ? 18.0 : (_myLocation != null ? 16.0 : 6.0),
              // AGGIUNTA FONDAMENTALE: Evento scatenato ad ogni movimento della mappa
              onPositionChanged: (MapCamera camera, bool hasGesture) {
                if (hasPlaces) {
                  // Controlla se il centro della zona è visibile nello schermo
                  final placeCenter = savedPlaces[selectedPlaceIndex!]['center'] as LatLng;
                  final isVisible = camera.visibleBounds.contains(placeCenter);
                  
                  // Se lo stato di visibilità cambia, aggiorna l'UI
                  if (_isPlaceInView != isVisible) {
                    setState(() {
                      _isPlaceInView = isVisible;
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
                      color: const Color(0xFF00C6B8).withOpacity(0.3),
                      borderColor: const Color(0xFF00C6B8),
                      borderStrokeWidth: 3,
                    ),
                  ],
                ),

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

              if (hasPlaces)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentPlace!['center'],
                      width: 30,
                      height: 30,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 30),
                    ),
                  ],
                ),
            ],
          ),

          // INTERFACCIA SUPERIORE
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(15.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: hasPlaces 
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(15),
                                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true, 
                                value: selectedPlaceIndex,
                                items: List.generate(
                                    savedPlaces.length,
                                    (i) => DropdownMenuItem(
                                        value: i, child: Text(savedPlaces[i]['name'], overflow: TextOverflow.ellipsis))),
                                onChanged: (val) {
                                  setState(() {
                                    selectedPlaceIndex = val!;
                                    _isPlaceInView = true; // Quando scelgo dalla tendina, forzo la visibilità
                                    _mapController.move(savedPlaces[val]['center'], 18.0);
                                  });
                                },
                              ),
                            ),
                          )
                        : Container(
                            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
                            child: const Text("Nessuna zona", style: TextStyle(color: Colors.grey)),
                          ),
                    ),
                    
                    const SizedBox(width: 10), 

                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton.small(
                          heroTag: "locatePet", 
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Localizzazione animale in fase di creazione..."))
                            );
                          },
                          backgroundColor: Colors.grey.shade400,
                          child: const Icon(Icons.pets, color: Colors.white),
                        ),
                        const SizedBox(width: 8),

                        FloatingActionButton.small(
                          heroTag: "locateMe", 
                          onPressed: () async {
                             ScaffoldMessenger.of(context).showSnackBar(
                               const SnackBar(content: Text("Ricerca posizione in corso..."), duration: Duration(seconds: 1))
                             );
                             await _determinePosition();
                          },
                          backgroundColor: Colors.white,
                          child: const Icon(Icons.smartphone, color: Colors.blueAccent),
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
                            color: const Color(0xFF00C6B8)
                          ),
                        ),
                        const SizedBox(width: 8),

                        FloatingActionButton.small(
                          heroTag: "addPlace",
                          onPressed: () => _showPlaceDialog(isEditing: false),
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

          // PANNELLO INFORMAZIONI IN BASSO - RESO DINAMICO SULLA BASE DELLA VISIBILITA'
          if (hasPlaces && _isPlaceInView)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      currentPlace!['name'],
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      "${currentPlace['city']} (${currentPlace['cap']}) - ${currentPlace['street']}, ${currentPlace['civic']}",
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.black45, fontSize: 13),
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        InkWell(
                          onTap: () => _showPlaceDialog(isEditing: true, editIndex: selectedPlaceIndex),
                          child: _buildSmallAction(Icons.edit, "Modifica", color: Colors.blueAccent)
                        ),
                        InkWell(
                          onTap: () {
                             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Impostazioni avvisi in arrivo...")));
                          },
                          child: _buildSmallAction(Icons.notifications_active, "Avvisi", color: Colors.grey.shade400)
                        ),
                        InkWell(
                          onTap: _confirmDeleteCurrentPlace,
                          child: _buildSmallAction(Icons.delete_outline, "Elimina", color: Colors.red)
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSmallAction(IconData icon, String label, {Color color = Colors.black45}) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}