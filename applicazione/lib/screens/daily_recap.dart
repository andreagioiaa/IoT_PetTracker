import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import '../repositories/activities_repo.dart';
import '../repositories/positions_repo.dart';
import '../services/authentication.dart' as scambio;

class RecapScreen extends StatefulWidget {
  final DateTime dataSelezionata;
  const RecapScreen({super.key, required this.dataSelezionata});

  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<RecapScreen> {
  final ActivitiesRepository _activitiesRepo = ActivitiesRepository(scambio.pb);
  final PositionsRepository _positionsRepo = PositionsRepository(scambio.pb);
  final MapController _mapController = MapController();

  bool _isLoading = true;
  List<LatLng> _routePoints = [];
  Map<String, dynamic> _stats = {'steps': 0, 'km': "0.0", 'minutes': 0};

  @override
  void initState() {
    super.initState();
    _caricaDatiCompleti();
  }

  /// Funzione per adattare la telecamera al percorso trovato
  void _fitBounds() {
    if (_routePoints.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Controllo critico: se c'è solo 1 punto, non usiamo fitCamera
      if (_routePoints.length == 1) {
        // Ci limitiamo a centrare la mappa sul punto con uno zoom fisso (es. 15.0)
        _mapController.move(_routePoints.first, 15.0);
      } else {
        // Se ci sono più punti, calcoliamo i confini normalmente
        final bounds = LatLngBounds.fromPoints(_routePoints);
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.all(50.0),
          ),
        );
      }
    });
  }

  Future<void> _caricaDatiCompleti() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // ⚠️ NOTA CRITICA: ID Board forzato per i test. Ricordati di renderlo dinamico.
      const String boardId = "864643061064939";

      // 1. Recupero Attività e calcolo statistiche
      final attivita = await _activitiesRepo.fetchActivitiesByDate(
          boardId, widget.dataSelezionata);

      int passiTotali = 0;
      Duration durataTotale = Duration.zero;

      for (var act in attivita) {
        passiTotali += act.totalSteps;
        if (act.startTime != null) {
          if (act.endTime != null) {
            final diff = act.endTime!.difference(act.startTime!);
            if (!diff.isNegative) durataTotale += diff;
          } else if (act.isActive) {
            // Gestione attività aperte nel passato o oggi
            DateTime fineRef =
                DateUtils.isSameDay(widget.dataSelezionata, DateTime.now())
                    ? DateTime.now()
                    : DateTime(
                        widget.dataSelezionata.year,
                        widget.dataSelezionata.month,
                        widget.dataSelezionata.day,
                        23,
                        59,
                        59);
            final diff = fineRef.difference(act.startTime!);
            if (!diff.isNegative) durataTotale += diff;
          }
        }
      }

      // 2. Recupero Posizioni GPS
      final posizioni =
          await _positionsRepo.fetchPositionsByDate(widget.dataSelezionata);
      print(
          "📍 Punti GPS recuperati per il ${widget.dataSelezionata}: ${posizioni.length}");
      final List<LatLng> points =
          posizioni.map((p) => LatLng(p.lat, p.lon)).toList();

      if (mounted) {
        setState(() {
          _stats = {
            'steps': passiTotali,
            'km': (passiTotali * 0.7 / 1000).toStringAsFixed(1),
            'minutes': durataTotale.inMinutes,
          };
          _routePoints = points;
          _isLoading = false;
        });

        // Eseguiamo lo zoom se abbiamo dei punti
        if (_routePoints.isNotEmpty) _fitBounds();
      }
    } catch (e) {
      debugPrint("❌ Errore recap: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String dataLabel =
        DateFormat('EEEE d MMMM', 'it_IT').format(widget.dataSelezionata);

    return Scaffold(
      appBar: AppBar(
        title: Text("Recap $dataLabel"),
        backgroundColor: const Color(0xFFF7F8FA),
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildStatsHeader(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(30)),
                child: _buildMap(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsHeader() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 15)
          ],
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStat(
                      "Passi", "${_stats['steps']}", Icons.pets, Colors.orange),
                  _buildStat(
                      "Km", "${_stats['km']}", Icons.straighten, Colors.blue),
                  _buildStat("Minuti", "${_stats['minutes']}", Icons.timer,
                      Colors.purple),
                ],
              ),
      ),
    );
  }

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: const MapOptions(
        initialCenter: LatLng(45.941, 13.471), // Cormons default
        initialZoom: 15.0,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.pettracker.app',
        ),
        if (_routePoints.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routePoints,
                strokeWidth: 5.0,
                color: const Color(0xFF00C6B8),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildStat(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 8),
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.black38, fontSize: 12)),
      ],
    );
  }
}
