import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'dart:async';
import 'dart:math' as math;
import 'scambio.dart' as scambio;
import 'home.dart';

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
  StreamSubscription<CompassEvent>? _compassSubscription;

  // Variabili per la bussola e stato
  double? _directionToPet;
  double? _phoneHeading;
  bool _isSatellite = true;

  // --- IL CUORE DEL CAMALEONTE: Il cane è al sicuro? ---
  bool _isPetSafe =
      true; // Di base assumiamo sia al sicuro finché non calcoliamo

  @override
  void initState() {
    super.initState();
    _inizializzaDati();
    _inizializzaBussola();
  }

  void _inizializzaBussola() {
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted && event.heading != null) {
        setState(() {
          _phoneHeading = event.heading;
        });
      }
    });
  }

  // ALGORITMO PER CALCOLARE L'ANGOLO (BEARING)
  void _ricalcolaDirezione() {
    if (_userLocation == null || _petLocation == null) return;

    final lat1 = _userLocation!.latitude * math.pi / 180;
    final lon1 = _userLocation!.longitude * math.pi / 180;
    final lat2 = _petLocation!.latitude * math.pi / 180;
    final lon2 = _petLocation!.longitude * math.pi / 180;

    final dLon = lon2 - lon1;

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    double brng = math.atan2(y, x) * 180 / math.pi;
    brng = (brng + 360) % 360;

    setState(() {
      _directionToPet = brng;
    });
  }

  // --- ALGORITMO GEOMETRICO PER CAPIRE SE È DENTRO UNA ZONA ---
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

  // --- CONTROLLA LO STATO DI SICUREZZA ---
  void _checkPetSafety() {
    if (_petLocation == null) return;

    // Se non ci sono zone attive salvate, vuol dire che è fuori da qualsiasi controllo
    if (_savedZones.isEmpty) {
      if (_isPetSafe != false) setState(() => _isPetSafe = false);
      return;
    }

    bool safe = false;
    for (var zone in _savedZones) {
      if (_isPointInPolygon(_petLocation!, zone['vertices'])) {
        safe = true;
        break;
      }
    }

    if (_isPetSafe != safe) {
      setState(() => _isPetSafe = safe);
    }
  }

  Future<void> _inizializzaDati() async {
    try {
      final geoResult = await scambio.pb.collection('geofences').getFullList();
      List<Map<String, dynamic>> activeZones = [];
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
          if (pts.length >= 3) activeZones.add({'vertices': pts});
        }
      }
      if (mounted) setState(() => _savedZones = activeZones);
    } catch (e) {
      debugPrint("Errore caricamento zone: $e");
    }

    try {
      final posResult = await scambio.pb
          .collection('positions')
          .getList(page: 1, perPage: 1, sort: '-timestamp');
      if (posResult.items.isNotEmpty) {
        final lat = posResult.items.first.getDoubleValue('lat');
        final lon = posResult.items.first.getDoubleValue('lon');
        if (mounted) {
          setState(() {
            _petLocation = LatLng(lat, lon);
            _history.add(_petLocation!);
            _ricalcolaDirezione();
          });
          _checkPetSafety(); // Controlla subito se è al sicuro
          _mapController.move(_petLocation!, 17.0);
        }
      }
    } catch (e) {
      debugPrint("Errore ultima pos: $e");
    }

    _petStreamSubscription = scambio.posizioneStream.listen((nuovoRecord) {
      try {
        final lat = nuovoRecord.getDoubleValue('lat');
        final lon = nuovoRecord.getDoubleValue('lon');
        final newPos = LatLng(lat, lon);

        if (mounted) {
          setState(() {
            _petLocation = newPos;
            if (_history.isEmpty || _history.last != newPos) {
              _history.add(newPos);
            }
            _ricalcolaDirezione();
          });
          _checkPetSafety(); // Controlla ogni volta che si muove!
        }
      } catch (e) {}
    });

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
              _ricalcolaDirezione();
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
    _compassSubscription?.cancel();
    super.dispose();
  }

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

  Widget _miniFAB(IconData icon, Color color, VoidCallback onPressed,
      bool isSmallScreen, String heroTag,
      {Color iconColor = Colors.white}) {
    return SizedBox(
      width: isSmallScreen ? 40 : 48,
      height: isSmallScreen ? 40 : 48,
      child: FloatingActionButton(
        heroTag: heroTag,
        backgroundColor: color,
        onPressed: onPressed,
        child: Icon(icon, color: iconColor, size: isSmallScreen ? 20 : 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    double scale = (screenWidth / 400).clamp(0.75, 1.1);
    final isSmallScreen = screenWidth < 360;

    double compassRotation = 0.0;
    if (_directionToPet != null && _phoneHeading != null) {
      compassRotation = (_directionToPet! - _phoneHeading!) * (math.pi / 180);
    }

    // Colore primario adattivo per banner e UI, l'arancione resta fisso per il pet
    final Color primaryColor =
        _isPetSafe ? const Color(0xFF00C6B8) : Colors.red.shade900;
    final Color petColor = Colors.orange; // Fisso!

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _petLocation ?? const LatLng(41.8719, 12.5674),
              initialZoom: 17.0,
            ),
            children: [
              TileLayer(
                urlTemplate: _isSatellite
                    ? 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pet_tracker',
              ),
              PolygonLayer(
                polygons: _savedZones.map((zone) {
                  return Polygon(
                    points: zone['vertices'],
                    color: const Color(0xFF00C6B8).withOpacity(0.3),
                    borderColor: const Color(0xFF00C6B8),
                    borderStrokeWidth: 3,
                  );
                }).toList(),
              ),
              if (_history.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _history,
                      color: petColor.withOpacity(0.8), // Scia arancione
                      strokeWidth: 5.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_userLocation != null)
                    Marker(
                      point: _userLocation!,
                      width: 60,
                      height: 60,
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
                              boxShadow: const [
                                BoxShadow(
                                    color: Colors.black26,
                                    blurRadius: 3,
                                    offset: Offset(0, 2))
                              ],
                            ),
                          ),
                        ],
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
                              color:
                                  petColor.withOpacity(0.3), // Sempre arancione
                            ),
                          ),
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: petColor, // Sempre arancione
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

          // --- BANNER IN ALTO ADATTIVO ---
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
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
                    primaryColor.withOpacity(0.9),
                    primaryColor.withOpacity(0.0)
                  ],
                ),
              ),
              child: Column(
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                            _isPetSafe
                                ? Icons.verified_user
                                : Icons.warning_rounded,
                            color: Colors.white,
                            size: 28 * scale),
                        SizedBox(width: 10 * scale),
                        Text(_isPetSafe ? "MONITORAGGIO" : "INSEGUIMENTO",
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 24 * scale,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 15, vertical: 8),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(25),
                          border: Border.all(color: Colors.white24)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_calcolaTestoDistanza(),
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16 * scale,
                                  fontWeight: FontWeight.bold)),
                          if (_directionToPet != null &&
                              _phoneHeading != null) ...[
                            SizedBox(width: 15 * scale),
                            Container(
                              width: 30 * scale,
                              height: 30 * scale,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withOpacity(0.1),
                              ),
                              child: Transform.rotate(
                                angle: compassRotation,
                                child: Icon(
                                  Icons.navigation,
                                  color: petColor, // Sempre arancione
                                  size: 20 * scale,
                                ),
                              ),
                            )
                          ] else ...[
                            SizedBox(width: 15 * scale),
                            SizedBox(
                              width: 15 * scale,
                              height: 15 * scale,
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white54,
                              ),
                            )
                          ]
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // --- PANNELLO TASTI IN BASSO ---
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _miniFAB(Icons.pets, Colors.white, () {
                  if (_petLocation != null) {
                    _mapController.move(_petLocation!, 18.0);
                  }
                }, isSmallScreen, "trackLocatePet", iconColor: petColor),
                const SizedBox(height: 10),
                _miniFAB(Icons.smartphone, Colors.white, () {
                  if (_userLocation != null) {
                    _mapController.move(_userLocation!, 18.0);
                  }
                }, isSmallScreen, "trackLocateMe",
                    iconColor: Colors.blueAccent),
                const SizedBox(height: 10),
                _miniFAB(
                    _isSatellite ? Icons.map : Icons.satellite_alt,
                    Colors.white,
                    () => setState(() => _isSatellite = !_isSatellite),
                    isSmallScreen,
                    "trackMapSwitch",
                    iconColor: const Color(0xFF00C6B8)),
                const SizedBox(height: 20),

                // --- BOTTONI DINAMICI ---
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _isPetSafe
                      ? const SizedBox.shrink(
                          key: ValueKey(
                              "SafeEmpty")) // <-- RIMOSSO IL TASTO QUI!
                      : Row(
                          key: const ValueKey("AlarmButtons"),
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.blueAccent,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 15),
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
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00C6B8),
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 15),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(15)),
                                  elevation: 10,
                                ),
                                icon: const Icon(Icons.check_circle_outline),
                                label: Text("Trovato!",
                                    style: TextStyle(
                                        fontSize: 14 * scale,
                                        fontWeight: FontWeight.bold)),
                                onPressed: () async {
                                  await scambio.setAllarme(false);
                                  isTrackingMode.value = false;
                                },
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
