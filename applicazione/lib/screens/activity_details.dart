import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pet_tracker/utils/helpers.dart';
import 'dart:async';
import '../models/activities.dart';
import '../repositories/positions_repo.dart';
import '../services/authentication.dart' as scambio;
import './globals/app_state.dart';
import '../models/statistics.dart';

class ActivityDetailsScreen extends StatefulWidget {
  final Activities attivita;
  final String titoloZona;
  final Color coloreStato;

  const ActivityDetailsScreen({
    super.key,
    required this.attivita,
    required this.titoloZona,
    required this.coloreStato,
  });

  @override
  State<ActivityDetailsScreen> createState() => _ActivityDetailsScreenState();
}

class _ActivityDetailsScreenState extends State<ActivityDetailsScreen> {
  final MapController _mapController = MapController();
  final PositionsRepository _positionsRepo = PositionsRepository(scambio.pb);

  bool _isLoading = true;
  bool _isSatellite = true;

  List<LatLng> _routePoints = [];
  LatLng? _userLocation;

  StreamSubscription<Position>? _userLocationStream;
  StreamSubscription? _dogPositionStream;

  // Inizializza l'oggetto con valori a zero tramite il costruttore empty()
  DailyStats _statisticheAttivita = DailyStats.empty();

  @override
  void initState() {
    super.initState();
    _caricaPercorso();
    _avviaStreamPosizioneUtente();

    if (widget.attivita.isActive == true) {
      _avviaStreamPosizioneCane();
    }
  }

  void _avviaStreamPosizioneCane() {
    _positionsRepo.subscribeToPositions();

    _dogPositionStream =
        _positionsRepo.positionsStream.listen((nuovaPos) async {
      if (!mounted) return;

      // Controlla se la posizione ricevuta appartenga all'attività attuale
      if (nuovaPos.activityId != widget.attivita.id) {
        return;
      }

      // 1. Calcoliamo la distanza percorsa rispetto all'ultimo punto registrato (se esiste)
      final nuovoPunto = LatLng(nuovaPos.lat, nuovaPos.lon);
      double kmAggiuntivi = 0.0;

      if (_routePoints.isNotEmpty) {
        const distanceCalc = Distance();
        // Calcola la distanza in metri tra l'ultimo punto registrato e il nuovo punto ricevuto
        final metri = distanceCalc.distance(_routePoints.last, nuovoPunto);

        // Evita di sommare micro-spostamenti dovuti all'errore del sensore (es. < 2 metri)
        if (metri > 2) {
          kmAggiuntivi = metri / 1000;
        }
      }

      // 2. RECUPERO PASSI: Interroghiamo la tabella 'activities' per avere i passi attuali
      int passiAggiornati = _statisticheAttivita.steps; // Valore di fallback
      try {
        // Facciamo una rapida query per prendere il record aggiornato dell'attività
        final activityRecord = await scambio.pb
            .collection('activities')
            .getOne(widget.attivita.id);
        passiAggiornati = activityRecord.getIntValue('total_steps');
      } catch (e) {
        debugPrint("Impossibile recuperare i passi aggiornati: $e");
      }

      // 3. Aggiorniamo la UI con tutti i dati fusi insieme!
      if (mounted) {
        setState(() {
          _routePoints.add(nuovoPunto); // Estendiamo la linea sulla mappa

          int nuoviMinuti = _statisticheAttivita.minutes;
          if (widget.attivita.startTime != null) {
            nuoviMinuti =
                DateTime.now().difference(widget.attivita.startTime!).inMinutes;
          }

          // Ricreiamo l'oggetto con GPS, Tempo e Passi freschi di database
          _statisticheAttivita = DailyStats(
            steps: passiAggiornati,
            km: _statisticheAttivita.km + kmAggiuntivi,
            minutes: nuoviMinuti,
          );
        });
      }
    });
  }

  Future<void> _caricaPercorso() async {
    // 1. Scarica le posizioni dal DB (restituisce List<Positions>)
    final posizioni =
        await _positionsRepo.fetchPositionsForActivity(widget.attivita.id);

    double kmCalcolati = 0.0;

    if (posizioni.isNotEmpty) {
      _routePoints = posizioni.map((p) => LatLng(p.lat, p.lon)).toList();

      // Trasformiamo le posizioni nel formato Mappa che si aspetta il calcolatore statico
      final posizioniPerCalcolo =
          posizioni.map((p) => {'lat': p.lat, 'lon': p.lon}).toList();

      // DELEGHIAMO IL CALCOLO DEI KM AL REPOSITORY
      kmCalcolati =
          PositionsRepository.calculateTotalDistance(posizioniPerCalcolo);

      // Calcola i limiti della mappa
      if (_routePoints.isNotEmpty) {
        final bounds = LatLngBounds.fromPoints(_routePoints);
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _mapController.fitCamera(
              CameraFit.bounds(
                  bounds: bounds, padding: const EdgeInsets.all(50.0)),
            );
          }
        });
      }
    }

    // 2. Calcola Passi e Minuti direttamente dall'oggetto Activities che abbiamo già
    int passi = widget.attivita.totalSteps;
    int minuti = 0;

    if (widget.attivita.startTime != null) {
      final start = widget.attivita.startTime!;
      final end = widget.attivita.endTime ?? DateTime.now();
      minuti = end.difference(start).inMinutes;
    }

    if (mounted) {
      setState(() {
        // 3. RIEMPIAMO IL MODELLO CONTENITORE!
        _statisticheAttivita = DailyStats(
          steps: passi,
          km: kmCalcolati,
          minutes: minuti,
        );
        _isLoading = false;
      });
    }
  }

  void _avviaStreamPosizioneUtente() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

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

  @override
  void dispose() {
    _userLocationStream?.cancel();
    _dogPositionStream?.cancel();
    super.dispose();
  }

  Widget _miniFAB(IconData icon, Color color, VoidCallback onPressed,
      {Color iconColor = Colors.white}) {
    return SizedBox(
      width: 45,
      height: 45,
      child: FloatingActionButton(
        heroTag: icon.codePoint.toString(), // Tag univoco per evitare errori
        backgroundColor: color,
        onPressed: onPressed,
        child: Icon(icon, color: iconColor, size: 22),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double scale = dimensioniSchermo(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: Text(widget.titoloZona,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: Stack(
        children: [
          // MAPPA
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _routePoints.isNotEmpty
                  ? _routePoints.first
                  : const LatLng(41.8719, 12.5674),
              initialZoom: 16.0,
            ),
            children: [
              TileLayer(
                urlTemplate: _isSatellite
                    ? 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pet_tracker',
              ),
              // Tracciato dell'attività
              if (_routePoints.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      color: widget.coloreStato.withOpacity(0.8),
                      strokeWidth: 6.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  // Posizione Utente
                  if (_userLocation != null)
                    Marker(
                      point: _userLocation!,
                      width: 20 * scale,
                      height: 20 * scale,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.blue,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  // Punto finale/attuale del cane
                  if (_routePoints.isNotEmpty)
                    Marker(
                      point: _routePoints.last,
                      width: 50,
                      height: 50,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.coloreStato.withOpacity(0.3),
                            ),
                          ),
                          Container(
                            width: 25,
                            height: 25,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.coloreStato,
                            ),
                            child: const Icon(Icons.pets,
                                color: Colors.white, size: 14),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),

          if (_isLoading)
            const Center(
                child: CircularProgressIndicator(color: Color(0xFF00C6B8))),

          // PANNELLO BOTTONI MAPPA (Destra)
          Positioned(
            top: 20,
            right: 15,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _miniFAB(Icons.pets, Colors.white, () {
                  if (_routePoints.isNotEmpty) {
                    final bounds = LatLngBounds.fromPoints(_routePoints);
                    _mapController.fitCamera(CameraFit.bounds(
                        bounds: bounds, padding: const EdgeInsets.all(50.0)));
                  }
                }, iconColor: widget.coloreStato),
                const SizedBox(height: 10),
                _miniFAB(
                  Icons.smartphone,
                  hasLocationPermission.value
                      ? Colors.white
                      : Colors.grey[300]!,
                  () {
                    if (_userLocation != null) {
                      _mapController.move(_userLocation!, 18.0);
                    }
                  },
                  iconColor: hasLocationPermission.value
                      ? Colors.blueAccent
                      : Colors.grey[600]!,
                ),
                const SizedBox(height: 10),
                _miniFAB(
                  _isSatellite ? Icons.map : Icons.satellite_alt,
                  Colors.white,
                  () => setState(() => _isSatellite = !_isSatellite),
                  iconColor: const Color(0xFF00C6B8),
                ),
              ],
            ),
          ),

          // PANNELLO STATISTICHE (Basso)
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(20 * scale),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24 * scale),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10))
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildCompactStat("Passi", "${_statisticheAttivita.steps}",
                      Icons.pets, Colors.orange, scale),
                  _buildCompactStat("Km", _statisticheAttivita.formattedKm,
                      Icons.straighten, Colors.blue, scale),
                  _buildCompactStat(
                      "Durata",
                      formattaTempoMinuti(_statisticheAttivita.minutes),
                      Icons.timer,
                      Colors.purple,
                      scale),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildCompactStat(
      String label, String value, IconData icon, Color color, double scale) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
            backgroundColor: color.withOpacity(0.1),
            radius: 20 * scale,
            child: Icon(icon, color: color, size: 22 * scale)),
        SizedBox(height: 8 * scale),
        Text(value,
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * scale)),
        Text(label,
            style: TextStyle(color: Colors.black45, fontSize: 12 * scale)),
      ],
    );
  }
}
