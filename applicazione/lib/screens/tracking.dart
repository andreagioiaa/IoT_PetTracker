import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pet_tracker/utils/helpers.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'dart:async';
import 'dart:math' as math;
import '../services/authentication.dart' as scambio;
import '../services/position_gps.dart';
import './globals/app_state.dart';
import '../repositories/users_repo.dart';
import "../repositories/positions_repo.dart";
import "../repositories/geofences_repo.dart";
import '../services/geocoding.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  // Controller per la mappa e repository per dati
  final MapController _mapController = MapController();
  final UsersRepository _usersRepo = UsersRepository();
  late final PositionsRepository _positionsRepo =
      PositionsRepository(scambio.pb);
  late final GeofenceRepository _geofenceRepo = GeofenceRepository(scambio.pb);

  // Variabile per sicnronizzazione allarme
  bool _isProcessingDiscovery = false;

  // Posizioni e cronologia
  LatLng? _petLocation;
  LatLng? _userLocation;

  // Cronologia delle posizioni del cane (per tracciare la scia)
  final List<LatLng> _history = [];
  List<Map<String, dynamic>> _savedZones = [];

  StreamSubscription? _petStreamSubscription;
  StreamSubscription<Position>? _userLocationStream;
  StreamSubscription<CompassEvent>? _compassSubscription;

  // Variabili per la bussola e stato
  double? _directionToPet;
  double? _phoneHeading;
  bool _isSatellite = true;

  // Stato di sicurezza del pet (true = in zona sicura, false = fuori)
  bool _isPetSafe = true;

  @override
  void initState() {
    super.initState();
    hasLocationPermission.addListener(_onPermissionChanged);
    _inizializzaDati();
  }

  void _onPermissionChanged() {
    if (mounted) setState(() {});
  }

  void _inizializzaBussola() {
    if (_compassSubscription != null) return;

    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted && event.heading != null) {
        setState(() {
          _phoneHeading = event.heading;
        });
      }
    });
  }

  //  Algoritmo di calcolo della direzione: utilizza la funzione di bearing per ottenere l'angolo esatto tra la posizione dell'utente e quella del pet
  void _ricalcolaDirezione() {
    if (_userLocation == null || _petLocation == null) return;

    const Distance distance = Distance();
    // Calcola direttamente l'angolo dal tuo punto a quello del cane
    double brng = distance.bearing(_userLocation!, _petLocation!);
    setState(() {
      _directionToPet = brng;
    });
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
      if (PositionGpsService.isPointInsidePolygon(
          _petLocation!, zone['vertices'])) {
        safe = true;
        break;
      }
    }

    if (_isPetSafe != safe) {
      setState(() => _isPetSafe = safe);
    }
  }

  // Funzione per preparare i dati con gestione degli errori e fallback
  Future<void> _inizializzaDati() async {
    final String? boardId = await _usersRepo.getBoardIdFromBoards();

    if (boardId == null) {
      debugPrint(
          "🛑 [TrackingScreen] Nessuna board trovata per questo utente!");
      return; // Ferma tutto se non c'è una board
    }

    try {
      final geofences = await _geofenceRepo.fetchGeofences(boardId);

      final activeZones =
          geofences.where((z) => z['is_active'] == true).toList();

      if (mounted) setState(() => _savedZones = activeZones);
    } catch (e) {
      debugPrint("Errore caricamento zone: $e");
    }

    try {
      final ultimaPos = await _positionsRepo.getLatestPosition(boardId);
      if (ultimaPos != null && mounted) {
        setState(() {
          _petLocation = LatLng(ultimaPos.lat, ultimaPos.lon);
          _history.add(_petLocation!);
          _ricalcolaDirezione();
        });
        _checkPetSafety();
        _mapController.move(_petLocation!, 18.0);
      }
    } catch (e) {
      debugPrint("Errore ultima pos: $e");
    }

    // 1. Attiviamo la sottoscrizione real-time nel repository
    _positionsRepo.subscribeToPositions(boardId);

    // 2. Ascoltiamo lo stream di oggetti 'Positions' (non più record grezzi)
    _petStreamSubscription =
        _positionsRepo.positionsStream.listen((nuovaPosizione) {
      try {
        final newPos = LatLng(nuovaPosizione.lat, nuovaPosizione.lon);

        if (mounted) {
          setState(() {
            _petLocation = newPos;

            // Gestione cronologia
            if (_history.isEmpty || _history.last != newPos) {
              _history.add(newPos);

              // Mantiene solo gli ultimi 100 punti per non far laggare l'app
              if (_history.length > 100) _history.removeAt(0);
            }

            _ricalcolaDirezione();
          });

          _checkPetSafety(); // Logica di sicurezza immutata
        }
      } catch (e) {
        debugPrint("🛑 Errore durante l'aggiornamento posizione: $e");
      }
    });

    await _checkAndStartLocation();
  }

  // Controlla se il servizio di localizzazione è attivo e se abbiamo i permessi, poi avvia lo stream della posizione dell'utente
  Future<void> _checkAndStartLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always) {
      hasLocationPermission.value = true;

      _avviaStreamPosizioneUtente();

      _inizializzaBussola();
    } else {
      hasLocationPermission.value = false;
    }
  }

  void _avviaStreamPosizioneUtente() {
    _userLocationStream ??= Geolocator.getPositionStream(
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

  @override
  void dispose() {
    hasLocationPermission.removeListener(_onPermissionChanged);
    _petStreamSubscription?.cancel();
    _userLocationStream?.cancel();
    _compassSubscription?.cancel();
    super.dispose();
  }

  // Funzione per calcolare il testo da mostrare nel banner in alto, con distanza e stato di rilevamento dell'animale e dell'utente
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
    double scale = dimensioniSchermo(context);
    final isSmallScreen = screenWidth < 360;

    double compassRotation = 0.0;
    if (_directionToPet != null && _phoneHeading != null) {
      compassRotation = (_directionToPet! - _phoneHeading!) * (math.pi / 180);
    }

    // Colore primario adattivo per banner e UI, cambia se il pet è in zona sicura o no
    final Color primaryColor =
        _isPetSafe ? const Color(0xFF00C6B8) : Colors.red.shade900;
    final Color petColor = Colors.orange;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _petLocation ?? const LatLng(41.8719, 12.5674),
              initialZoom: 18.0,
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
                              color: petColor.withOpacity(0.3),
                            ),
                          ),
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: petColor,
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
                  if (hasLocationPermission.value)
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
                _miniFAB(
                  Icons.smartphone,
                  hasLocationPermission.value
                      ? Colors.white
                      : Colors.grey[300]!,
                  () {
                    if (!hasLocationPermission.value) {
                      // Non chiede i permessi, mostra direttamente l'errore se non li ha
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content:
                                Text("Attiva la posizione nelle impostazioni."),
                            backgroundColor: Colors.grey,
                          ),
                        );
                      }
                    } else {
                      // Se ha i permessi, sposta la mappa
                      if (_userLocation != null) {
                        _mapController.move(_userLocation!, 18.0);
                      }
                    }
                  },
                  isSmallScreen,
                  "trackLocateMe",
                  iconColor: hasLocationPermission.value
                      ? Colors.blueAccent
                      : Colors.grey[600]!,
                ),
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
                      ? const SizedBox.shrink(key: ValueKey("SafeEmpty"))
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
                                onPressed: () async {
                                  if (_petLocation != null) {
                                    // Chiamata alla funzione dentro Geocoding
                                    bool success = await Geocoding.openNavigator(_petLocation!);
                                    
                                    if (!success && mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text("Impossibile aprire il navigatore.")),
                                      );
                                    }
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00C6B8),
                                  foregroundColor: Colors.white,
                                ),
                                icon: _isProcessingDiscovery
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2))
                                    : const Icon(Icons.check_circle_outline),
                                label: Text(_isProcessingDiscovery
                                    ? "Sincronizzazione..."
                                    : "Trovato!"),
                                onPressed: _isProcessingDiscovery
                                    ? null
                                    : () async {
                                        setState(() =>
                                            _isProcessingDiscovery = true);
                                        try {
                                          // Aggiorna il DB
                                          bool success = await _usersRepo
                                              .updateAlarm(false);
                                          if (success) {
                                            isTrackingMode.value =
                                                false; // Questo notifica la Home di cambiare tab
                                          }
                                        } catch (e) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text(
                                                      "Errore nel salvataggio. Riprova.")));
                                        } finally {
                                          if (mounted) {
                                            setState(() =>
                                                _isProcessingDiscovery = false);
                                          }
                                        }
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
