import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class GeofencingScreen extends StatefulWidget {
  const GeofencingScreen({Key? key}) : super(key: key);

  @override
  State<GeofencingScreen> createState() => _GeofencingScreenState();
}

class _GeofencingScreenState extends State<GeofencingScreen> {
  List<Map<String, dynamic>> savedPlaces = [

  ];

  int? selectedPlaceIndex = 0;
  final MapController _mapController = MapController();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _streetController = TextEditingController();
  final TextEditingController _civicController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  final TextEditingController _capController = TextEditingController();

  double _tempRadius = 30.0;

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
                content: Text(isUpdating
                    ? "Zona '$name' aggiornata!"
                    : "Zona '$name' creata!"),
                backgroundColor: Colors.green),
          );
          return true;
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Errore: Indirizzo inesistente."),
                backgroundColor: Colors.red),
          );
          return false;
        }
      } else {
        return false;
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Errore di rete: $e"), backgroundColor: Colors.red),
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
                      decoration: const InputDecoration(
                          labelText: "Nome luogo", hintText: "Es. Casa Mia"),
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
                                  hintText: "Es. Via Roma"),
                              enabled: !isLoading)),
                      const SizedBox(width: 10),
                      Expanded(
                          flex: 1,
                          child: TextField(
                              controller: _civicController,
                              decoration: const InputDecoration(
                                  labelText: "N°", hintText: "Civico"),
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
                          max:
                              50.0, // <-- Modificato a 50 metri (diametro totale 100m)
                          divisions:
                              8, // Diviso in step di 5 metri (10, 15, 20... 50)
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
                        final street =
                            _streetController.text.trim().toLowerCase();
                        final civic =
                            _civicController.text.trim().toLowerCase();
                        final city = _cityController.text.trim().toLowerCase();
                        final cap = _capController.text.trim();

                        if (name.isEmpty ||
                            city.isEmpty ||
                            street.isEmpty ||
                            civic.isEmpty ||
                            cap.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Compila tutti i campi"),
                                  backgroundColor: Colors.orange));
                          return;
                        }

                        bool nameExists = savedPlaces.asMap().entries.any(
                            (entry) =>
                                entry.key != editIndex &&
                                entry.value['name'].toString().toLowerCase() ==
                                    name.toLowerCase());
                        if (nameExists) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Nome già in uso."),
                                  backgroundColor: Colors.redAccent));
                          return;
                        }

                        bool addressExists = savedPlaces.asMap().entries.any(
                            (entry) =>
                                entry.key != editIndex &&
                                entry.value['street']
                                        .toString()
                                        .toLowerCase() ==
                                    street &&
                                entry.value['civic'].toString().toLowerCase() ==
                                    civic &&
                                entry.value['city'].toString().toLowerCase() ==
                                    city &&
                                entry.value['cap'].toString() == cap);
                        if (addressExists) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Indirizzo già configurato."),
                                  backgroundColor: Colors.redAccent));
                          return;
                        }

                        setDialogState(() {
                          isLoading = true;
                        });

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
                      },
                child: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(isEditing ? "Aggiorna" : "Cerca e Salva"),
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
              onPressed: () {
                setState(() {
                  savedPlaces.removeAt(selectedPlaceIndex!);
                  if (savedPlaces.isEmpty) {
                    selectedPlaceIndex = null;
                  } else {
                    selectedPlaceIndex = 0;
                    _mapController.move(savedPlaces[0]['center'], 18.0);
                  }
                });
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text("Zona '$placeName' eliminata."),
                      backgroundColor: Colors.black87),
                );
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

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: hasPlaces
                  ? currentPlace!['center']
                  : const LatLng(41.8719, 12.5674),
              initialZoom: hasPlaces ? 18.0 : 6.0,
            ),
            children: [
              TileLayer(
                // Abbiamo sostituito l'URL di OpenStreetMap con quello satellitare di Esri
                urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
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
              if (hasPlaces)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentPlace!['center'],
                      width: 30,
                      height: 30,
                      child: const Icon(Icons.location_on,
                          color: Colors.red, size: 30),
                    ),
                  ],
                ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(15.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (hasPlaces)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15),
                          boxShadow: const [
                            BoxShadow(color: Colors.black12, blurRadius: 10)
                          ]),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: selectedPlaceIndex,
                          items: List.generate(
                              savedPlaces.length,
                              (i) => DropdownMenuItem(
                                  value: i,
                                  child: Text(savedPlaces[i]['name']))),
                          onChanged: (val) {
                            setState(() {
                              selectedPlaceIndex = val!;
                              _mapController.move(
                                  savedPlaces[val]['center'], 18.0);
                            });
                          },
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 15, vertical: 10),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15)),
                      child: const Text("Nessuna zona salvata",
                          style: TextStyle(color: Colors.grey)),
                    ),
                  FloatingActionButton.small(
                    onPressed: () => _showPlaceDialog(isEditing: false),
                    backgroundColor: const Color(0xFF00C6B8),
                    child: const Icon(Icons.add, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          if (hasPlaces)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
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
                      style:
                          const TextStyle(color: Colors.black45, fontSize: 13),
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        // Tasto Modifica: Blu/Azzurro per indicare l'azione primaria modificabile
                        InkWell(
                            onTap: () => _showPlaceDialog(
                                isEditing: true, editIndex: selectedPlaceIndex),
                            child: _buildSmallAction(Icons.edit, "Modifica",
                                color: Colors.blueAccent)),
                        // Tasto Avvisi: Grigio in attesa di implementazione
                        // TODO: Quando collegato a Datacake, cambiare color: Colors.amber o Colors.orange
                        InkWell(
                            onTap: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Impostazioni avvisi in arrivo...")));
                            },
                            child: _buildSmallAction(
                                Icons.notifications_active, "Avvisi",
                                color: Colors.grey.shade400)),
                        // Tasto Elimina: Rosso per l'azione distruttiva
                        InkWell(
                            onTap: _confirmDeleteCurrentPlace,
                            child: _buildSmallAction(
                                Icons.delete_outline, "Elimina",
                                color: Colors.red)),
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

  // Aggiunto parametro color per personalizzare i bottoni facilmente
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
