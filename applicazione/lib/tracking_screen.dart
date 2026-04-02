import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'scambio.dart' as scambio;

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  final MapController _mapController = MapController();

  LatLng? _petLocation;
  LatLng? _userLocation;

  final List<LatLng> _history = [];
  List<Map<String, dynamic>> _savedZones = [];

  StreamSubscription? _petStreamSubscription;
  StreamSubscription<Position>? _userLocationStream;

  @override
  void initState() {
    super.initState();
    _inizializzaDati();
  }

  Future<void> _inizializzaDati() async {
    // 1. Scarica le zone sicure per disegnarle sbiadite (effetto "zona vietata")
    try {
      final geoResult =
          await scambio.pb.collection('geofences_test').getFullList();
      List<Map<String, dynamic>> zones = [];
      for (var record in geoResult) {
        if (record.getBoolValue('is_active') == true) {
          List<LatLng> pts = [];
          final rawList = record.getListValue<dynamic>('vertices');
          for (var pt in rawList) {
            if (pt is List && pt.length >= 2) {
              pts.add(LatLng(double.parse(pt[0].toString()),
                  double.parse(pt[1].toString())));
            }
          }
          if (pts.length >= 3) zones.add({'vertices': pts});
        }
      }
      if (mounted) setState(() => _savedZones = zones);
    } catch (e) {
      debugPrint("Errore caricamento zone: $e");
    }

    // 2. Prende l'ultima posizione nota per centrare subito la mappa
    try {
      final posResult = await scambio.pb
          .collection('positions_test')
          .getList(page: 1, perPage: 1, sort: '-timestamp');
      if (posResult.items.isNotEmpty) {
        final lat = posResult.items.first.getDoubleValue('lat');
        final lon = posResult.items.first.getDoubleValue('lon');
        if (mounted) {
          setState(() {
            _petLocation = LatLng(lat, lon);
            _history.add(_petLocation!);
          });
          _mapController.move(_petLocation!, 17.0);
        }
      }
    } catch (e) {
      debugPrint("Errore ultima pos: $e");
    }

    // 3. Si mette in ascolto sul TUBO in tempo reale!
    _petStreamSubscription = scambio.posizioneStream.listen((nuovoRecord) {
      try {
        final lat = nuovoRecord.getDoubleValue('lat');
        final lon = nuovoRecord.getDoubleValue('lon');
        final newPos = LatLng(lat, lon);

        if (mounted) {
          setState(() {
            _petLocation = newPos;
            // Aggiunge alla scia solo se si è mosso
            if (_history.isEmpty || _history.last != newPos) {
              _history.add(newPos);
            }
          });
          _mapController.move(
              newPos, 17.0); // Segue il cane come una telecamera
        }
      } catch (e) {}
    });

    // 4. Accende il GPS del telefono dell'utente per calcolare la distanza
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (serviceEnabled) {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        _userLocationStream = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high, distanceFilter: 5),
        ).listen((Position pos) {
          if (mounted) {
            setState(() {
              _userLocation = LatLng(pos.latitude, pos.longitude);
            });
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _petStreamSubscription?.cancel();
    _userLocationStream?.cancel();
    super.dispose();
  }

  // --- MAGIA: APRE GOOGLE MAPS SUL TELEFONO ---
  Future<void> _apriNavigatore() async {
    if (_petLocation == null) return;
    final url = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${_petLocation!.latitude},${_petLocation!.longitude}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Impossibile aprire il navigatore.")));
      }
    }
  }

  String _calcolaTestoDistanza() {
    if (_petLocation == null) return "Rilevamento animale...";
    if (_userLocation == null) return "Rilevamento tua posizione...";

    final double metri =
        const Distance().distance(_userLocation!, _petLocation!);

    if (metri > 1000) {
      return "A ${(metri / 1000).toStringAsFixed(1)} km da te";
    }
    return "A ${metri.toInt()} metri da te";
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    double scale = (screenWidth / 400).clamp(0.75, 1.1);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // --- 1. LA MAPPA SATELLITARE ---
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _petLocation ?? const LatLng(41.8719, 12.5674),
              initialZoom: 17.0,
            ),
            children: [
              // Satellitare di Google: perfetto per orientarsi al volo
              TileLayer(
                urlTemplate:
                    'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}',
                userAgentPackageName: 'com.example.pet_tracker',
              ),

              // Disegna le tue "Aree Sicure" in grigio opaco per capire dove sono i confini
              PolygonLayer(
                polygons: _savedZones.map((zone) {
                  return Polygon(
                    points: zone['vertices'],
                    color: Colors.white.withOpacity(0.15),
                    borderColor: Colors.white54,
                    borderStrokeWidth: 2,
                  );
                }).toList(),
              ),

              // La Scia del percorso dell'animale
              if (_history.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _history,
                      color: Colors.orangeAccent,
                      strokeWidth: 5.0,
                    ),
                  ],
                ),

              // I Segnaposti (Io e il Cane)
              MarkerLayer(
                markers: [
                  if (_userLocation != null)
                    Marker(
                      point: _userLocation!,
                      width: 40,
                      height: 40,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.blueAccent,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 5)
                          ],
                        ),
                        child: const Icon(Icons.person,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  if (_petLocation != null)
                    Marker(
                      point: _petLocation!,
                      width: 60,
                      height: 60,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.red.withOpacity(0.3),
                            ),
                          ),
                          Container(
                            width: 30,
                            height: 30,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.redAccent,
                            ),
                            child: const Icon(Icons.pets,
                                color: Colors.white, size: 18),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),

          // --- 2. BANNER ROSSO IN ALTO ---
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 15,
                  bottom: 20,
                  left: 20,
                  right: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.red.shade900.withOpacity(0.9),
                    Colors.red.shade900.withOpacity(0.0)
                  ],
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.warning_rounded,
                          color: Colors.white, size: 30),
                      const SizedBox(width: 10),
                      Text("INSEGUIMENTO LIVE",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22 * scale,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
                    decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(_calcolaTestoDistanza(),
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16 * scale,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),

          // --- 3. PANNELLO TASTI IN BASSO ---
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Tasto "Centra Mappa"
                FloatingActionButton(
                  heroTag: "centerPet",
                  backgroundColor: Colors.white,
                  onPressed: () {
                    if (_petLocation != null) {
                      _mapController.move(_petLocation!, 17.0);
                    }
                  },
                  child: const Icon(Icons.my_location, color: Colors.red),
                ),
                const SizedBox(height: 15),

                // Due super bottoni
                Row(
                  children: [
                    // Tasto Apri Navigatore
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.blueAccent,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15)),
                          elevation: 10,
                        ),
                        icon: const Icon(Icons.directions_run),
                        label: Text("Portami Lì",
                            style: TextStyle(
                                fontSize: 14 * scale,
                                fontWeight: FontWeight.bold)),
                        onPressed: _apriNavigatore,
                      ),
                    ),
                    const SizedBox(width: 15),

                    // Tasto Chiudi Emergenza
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              const Color(0xFF00C6B8), // Verde Acqua
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15)),
                          elevation: 10,
                        ),
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text("Trovato!",
                            style: TextStyle(
                                fontSize: 14 * scale,
                                fontWeight: FontWeight.bold)),
                        onPressed: () {
                          // Chiude la pagina e torna alla Home!
                          Navigator.pop(context);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
