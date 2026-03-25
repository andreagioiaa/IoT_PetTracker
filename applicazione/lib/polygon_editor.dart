import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'scambio.dart' as scambio;

class PolygonEditorScreen extends StatefulWidget {
  final String placeId;
  final String placeName;
  final LatLng initialCenter;
  final List<LatLng> initialVertices;

  const PolygonEditorScreen({
    Key? key,
    required this.placeId,
    required this.placeName,
    required this.initialCenter,
    required this.initialVertices,
  }) : super(key: key);

  @override
  State<PolygonEditorScreen> createState() => _PolygonEditorScreenState();
}

class _PolygonEditorScreenState extends State<PolygonEditorScreen> {
  List<LatLng> _points = [];
  bool _isSatellite = true;
  bool _isSaving = false;

  late bool _isNewZone; // Determina se siamo in Creazione o Modifica
  bool _isForceExiting = false;

  @override
  void initState() {
    super.initState();
    _points = List.from(widget.initialVertices);
    // Se non ci sono vertici iniziali, è matematicamente una nuova zona
    _isNewZone = widget.initialVertices.isEmpty;
  }

  void _addPoint(TapPosition tapPosition, LatLng point) {
    setState(() {
      _points.add(point);
    });
  }

  void _undoLastPoint() {
    if (_points.isNotEmpty) {
      setState(() {
        _points.removeLast();
      });
    }
  }

  void _clearAll() {
    setState(() {
      _points.clear();
    });
  }

  Future<void> _savePolygon() async {
    if (_points.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Servono almeno 3 punti per creare un'area sicura!"),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final jsonVertices =
          _points.map((p) => [p.latitude, p.longitude]).toList();

      await scambio.pb
          .collection('geofences_test')
          .update(widget.placeId, body: {
        "vertices": jsonVertices,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Perimetro salvato con successo!"),
              backgroundColor: Colors.green),
        );

        _isForceExiting = true;
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Errore salvataggio: $e"),
            backgroundColor: Colors.red),
      );
    }
  }

  // Gestione del tasto indietro (fisico/swipe Android)
  Future<bool> _onWillPop() async {
    if (_isForceExiting) return true; // Salvataggio avvenuto con successo

    if (_isNewZone) {
      // È una zona nuova: non si può uscire senza salvare
      _showExitErrorDialog();
      return false;
    }

    // È una zona in modifica: ha già i punti nel DB, può uscire liberamente
    return true;
  }

  void _showExitErrorDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Azione non consentita",
            style: TextStyle(color: Colors.red)),
        content: const Text(
          "Stai configurando una nuova zona.\n\n"
          "Devi tracciare e salvare un'area di almeno 3 vertici per poter proseguire.",
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C6B8)),
            onPressed: () => Navigator.pop(context),
            child:
                const Text("Ho capito", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        body: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: widget.initialCenter,
                initialZoom: 19.0,
                onTap: _addPoint,
              ),
              children: [
                TileLayer(
                  urlTemplate: _isSatellite
                      ? 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}'
                      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.pet_tracker',
                ),
                if (_points.length >= 3)
                  PolygonLayer(
                    polygons: [
                      Polygon(
                        points: _points,
                        color: const Color(0xFF00C6B8).withOpacity(0.4),
                        borderColor: const Color(0xFF00C6B8),
                        borderStrokeWidth: 3,
                        isFilled: true,
                      ),
                    ],
                  ),
                if (_points.length == 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _points,
                        color: const Color(0xFF00C6B8),
                        strokeWidth: 3,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: _points
                      .map((point) => Marker(
                            point: point,
                            width: 15,
                            height: 15,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.black, width: 2),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: widget.initialCenter,
                      width: 30,
                      height: 30,
                      child: const Icon(Icons.location_on,
                          color: Colors.redAccent, size: 30),
                    ),
                  ],
                ),
              ],
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(15.0),
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          )
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 8, right: 20, top: 12, bottom: 8),
                            child: Row(
                              children: [
                                // MOSTRA IL TASTO SOLO SE NON E' UNA NUOVA ZONA
                                if (!_isNewZone)
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back_ios_new,
                                        size: 20, color: Color(0xFF2D3142)),
                                    onPressed: () async {
                                      if (await _onWillPop()) {
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      }
                                    },
                                  ),
                                Expanded(
                                  child: Padding(
                                    // Aggiunge un po' di margine se il tasto back non c'è
                                    padding: EdgeInsets.only(
                                        left: _isNewZone ? 12.0 : 0.0),
                                    child: Text(
                                      // CAMBIA TESTO IN BASE ALLO STATO
                                      _isNewZone
                                          ? "Crea Zona: ${widget.placeName}"
                                          : "Modifica Area: ${widget.placeName}",
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF2D3142),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: _points.length >= 3
                                        ? Colors.green.withOpacity(0.1)
                                        : Colors.orange.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    "${_points.length} punto/i",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: _points.length >= 3
                                          ? Colors.green
                                          : Colors.orange,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0xFFE5E5EA)),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: const BoxDecoration(
                              color: Color(0xFFFAFAFA),
                              borderRadius: BorderRadius.only(
                                  bottomLeft: Radius.circular(20),
                                  bottomRight: Radius.circular(20)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                    _points.length >= 3
                                        ? Icons.check_circle_outline
                                        : Icons.touch_app,
                                    size: 16,
                                    color: _points.length >= 3
                                        ? Colors.green
                                        : Colors.black54),
                                const SizedBox(width: 8),
                                Text(
                                  _points.length >= 3
                                      ? "Area valida, puoi salvare o aggiungere punti."
                                      : "Tocca la mappa per creare almeno 3 vertici.",
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: _points.length >= 3
                                        ? Colors.green[700]
                                        : Colors.black54,
                                    fontWeight: _points.length >= 3
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        FloatingActionButton(
                          heroTag: "polySat",
                          backgroundColor: Colors.white,
                          onPressed: () =>
                              setState(() => _isSatellite = !_isSatellite),
                          child: Icon(
                              _isSatellite ? Icons.map : Icons.satellite_alt,
                              color: Colors.blue),
                        ),
                        Row(
                          children: [
                            if (_points.isNotEmpty)
                              FloatingActionButton(
                                heroTag: "polyClear",
                                backgroundColor: Colors.redAccent,
                                mini: true,
                                onPressed: _clearAll,
                                child: const Icon(Icons.delete_sweep,
                                    color: Colors.white),
                              ),
                            const SizedBox(width: 10),
                            if (_points.isNotEmpty)
                              FloatingActionButton(
                                heroTag: "polyUndo",
                                backgroundColor: Colors.orange,
                                onPressed: _undoLastPoint,
                                child:
                                    const Icon(Icons.undo, color: Colors.white),
                              ),
                            const SizedBox(width: 10),
                            FloatingActionButton(
                              heroTag: "polySave",
                              backgroundColor: _points.length >= 3
                                  ? Colors.green
                                  : Colors.grey,
                              onPressed: _isSaving ? null : _savePolygon,
                              child: _isSaving
                                  ? const CircularProgressIndicator(
                                      color: Colors.white)
                                  : const Icon(Icons.check,
                                      color: Colors.white),
                            ),
                          ],
                        )
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
