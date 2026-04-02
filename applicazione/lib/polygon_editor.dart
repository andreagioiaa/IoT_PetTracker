import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'scambio.dart' as scambio;

class PolygonEditorScreen extends StatefulWidget {
  final String? placeId;
  final Map<String, dynamic>? newZoneData;
  final String placeName;
  final LatLng initialCenter;
  final List<LatLng> initialVertices;

  const PolygonEditorScreen({
    super.key,
    this.placeId,
    this.newZoneData,
    required this.placeName,
    required this.initialCenter,
    required this.initialVertices,
  });

  @override
  State<PolygonEditorScreen> createState() => _PolygonEditorScreenState();
}

class _PolygonEditorScreenState extends State<PolygonEditorScreen> {
  List<LatLng> _points = [];
  bool _isSatellite = true;
  bool _isSaving = false;

  late bool _isNewZone;
  bool _isForceExiting = false;

  // Controller e chiave per mappare le coordinate dello schermo
  final MapController _mapController = MapController();
  final GlobalKey _mapKey = GlobalKey();

  // Indice del punto che stiamo trascinando in questo momento
  int? _draggedPointIndex;

  @override
  void initState() {
    super.initState();
    _points = List.from(widget.initialVertices);
    _isNewZone = widget.initialVertices.isEmpty;
  }

  void _addPoint(TapPosition tapPosition, LatLng point) {
    // Evitiamo di aggiungere punti se stiamo attualmente trascinando qualcosa
    if (_draggedPointIndex != null) return;

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

  // --- ALGORITMO GEOMETRICO (Usato per calcolare le sovrapposizioni) ---
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

  // --- DIALOG DI ERRORE PERSONALIZZATO ---
  void _showValidationDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(message),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C6B8)),
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text("Ho capito", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
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
      // ---------------------------------------------------------
      // 1. CONTROLLO DI LONTANANZA (Troppo distanti dal marker rosso)
      // ---------------------------------------------------------
      double sumLat = 0;
      double sumLon = 0;
      for (var p in _points) {
        sumLat += p.latitude;
        sumLon += p.longitude;
      }
      // Calcoliamo il baricentro del disegno
      LatLng centroid =
          LatLng(sumLat / _points.length, sumLon / _points.length);

      const distance = Distance();
      double distFromCenter = distance(widget.initialCenter, centroid);

      if (distFromCenter > 50) {
        setState(() => _isSaving = false);
        _showValidationDialog(
          "Area troppo lontana",
          "L'area che hai disegnato dista circa ${(distFromCenter / 1000).toStringAsFixed(1)} km dall'indirizzo selezionato.\n\nAvvicina il perimetro al segnaposto rosso o inserisci un nuovo indirizzo.",
        );
        return;
      }

      // ---------------------------------------------------------
      // 2. CONTROLLO DI SOVRAPPOSIZIONE (Anti-Conflitto tra Aree)
      // ---------------------------------------------------------
      final records =
          await scambio.pb.collection('geofences_test').getFullList();
      List<Map<String, dynamic>> existingZones = [];

      for (var res in records) {
        // Ignoriamo la zona stessa se la stiamo solo modificando
        if (res.id == widget.placeId) continue;

        List<LatLng> pts = [];
        try {
          final rawList = res.getListValue<dynamic>('vertices');
          for (var pt in rawList) {
            if (pt is List && pt.length >= 2) {
              pts.add(LatLng(double.parse(pt[0].toString()),
                  double.parse(pt[1].toString())));
            }
          }
        } catch (_) {} // ignoriamo errori di parsing sui vecchi record

        if (pts.length >= 3) {
          existingZones
              .add({"name": res.getStringValue('name'), "vertices": pts});
        }
      }

      String? overlappingZoneName;

      for (var zone in existingZones) {
        List<LatLng> existingPoly = zone['vertices'];
        bool overlap = false;

        // Caso A: I punti della zona in creazione cadono in una vecchia zona?
        for (var p in _points) {
          if (_isPointInPolygon(p, existingPoly)) {
            overlap = true;
            break;
          }
        }

        // Caso B: I punti di una vecchia zona cadono nel disegno attuale?
        if (!overlap) {
          for (var p in existingPoly) {
            if (_isPointInPolygon(p, _points)) {
              overlap = true;
              break;
            }
          }
        }

        if (overlap) {
          overlappingZoneName = zone['name'];
          break;
        }
      }

      if (overlappingZoneName != null) {
        setState(() => _isSaving = false);
        _showValidationDialog(
          "Sovrapposizione rilevata",
          "Il perimetro che stai creando si sovrappone a un'Area Sicura già esistente ('$overlappingZoneName').\n\nNon è possibile avere aree che si incrociano. Modifica i vertici e riprova.",
        );
        return;
      }

      // ---------------------------------------------------------
      // 3. SALVATAGGIO SUL DATABASE
      // ---------------------------------------------------------
      final jsonVertices =
          _points.map((p) => [p.latitude, p.longitude]).toList();

      String? savedZoneId;

      if (widget.placeId != null) {
        // MODIFICA ZONA ESISTENTE
        final rec = await scambio.pb
            .collection('geofences_test')
            .update(widget.placeId!, body: {
          "vertices": jsonVertices,
        });
        savedZoneId = rec.id;
      } else if (widget.newZoneData != null) {
        // CREAZIONE NUOVA ZONA
        final bodyToSave = Map<String, dynamic>.from(widget.newZoneData!);
        bodyToSave["vertices"] = jsonVertices;
        final rec = await scambio.pb
            .collection('geofences_test')
            .create(body: bodyToSave);
        savedZoneId = rec.id;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Perimetro salvato con successo!"),
              backgroundColor: Colors.green),
        );

        _isForceExiting = true;
        Navigator.pop(context, savedZoneId);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text("Errore salvataggio: $e"),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<bool> _onWillPop() async {
    if (_isForceExiting) return true;

    if (_isNewZone) {
      _showExitErrorDialog();
      return false;
    }

    return true;
  }

  void _showExitErrorDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Interrompere creazione?"),
        content: const Text(
          "Se esci ora, la nuova zona non verrà salvata nel database.\n\n"
          "Vuoi davvero annullare l'operazione?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Continua a disegnare",
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context); // Chiude il dialog
              _isForceExiting = true;
              Navigator.pop(
                  context, false); // Esce tornando alla mappa senza salvare
            },
            child: const Text("Annulla creazione",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // Helper per i pulsanti FAB compatti
  Widget _miniFAB(IconData icon, Color color, VoidCallback onPressed,
      bool isSmallScreen, String heroTag) {
    return SizedBox(
      width: isSmallScreen ? 40 : 48,
      height: isSmallScreen ? 40 : 48,
      child: FloatingActionButton(
        heroTag: heroTag,
        backgroundColor: color,
        onPressed: onPressed,
        child: Icon(icon, color: Colors.white, size: isSmallScreen ? 20 : 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1. Lettura delle dimensioni dello schermo
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final isSmallScreen = screenWidth < 360;

    // 2. Calcolo dinamico della grandezza del font del titolo
    double titleFontSize = screenWidth * 0.045;
    if (titleFontSize > 18) titleFontSize = 18;
    if (titleFontSize < 14) titleFontSize = 14;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        body: Stack(
          children: [
            FlutterMap(
              key: _mapKey,
              mapController: _mapController,
              options: MapOptions(
                initialCenter: widget.initialCenter,
                initialZoom: 19.0,
                onTap: _addPoint,
                // Disabilita il trascinamento della mappa se stiamo spostando un punto
                interactionOptions: InteractionOptions(
                  flags: _draggedPointIndex != null
                      ? InteractiveFlag.all & ~InteractiveFlag.drag
                      : InteractiveFlag.all,
                ),
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

                // --- LOGICA DI TRASCINAMENTO ---
                MarkerLayer(
                  markers: List.generate(_points.length, (index) {
                    return Marker(
                      point: _points[index],
                      width: 60, // Hitbox comoda per il tocco mobile
                      height: 60,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) {
                          setState(() {
                            _draggedPointIndex = index;
                          });
                        },
                        onPointerMove: (event) {
                          if (_draggedPointIndex == index &&
                              _mapKey.currentContext != null) {
                            final RenderBox box = _mapKey.currentContext!
                                .findRenderObject() as RenderBox;

                            final localPos = box.globalToLocal(event.position);
                            final latLng =
                                _mapController.camera.offsetToCrs(localPos);

                            setState(() {
                              _points[index] = latLng;
                            });
                          }
                        },
                        onPointerUp: (_) {
                          setState(() {
                            _draggedPointIndex = null;
                          });
                        },
                        onPointerCancel: (_) {
                          setState(() {
                            _draggedPointIndex = null;
                          });
                        },
                        child: Center(
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.blueAccent, width: 3),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black45,
                                  blurRadius: 4,
                                  offset: Offset(0, 2),
                                )
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                // --- FINE LOGICA TRASCINAMENTO ---

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
                // Padding dinamico ai lati
                padding: EdgeInsets.all(screenWidth * 0.04),
                child: Column(
                  children: [
                    // --- HEADER ---
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
                                left: 8, right: 16, top: 12, bottom: 8),
                            child: Row(
                              children: [
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
                                    padding: EdgeInsets.only(
                                        left: _isNewZone ? 12.0 : 0.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          _isNewZone
                                              ? "CREA ZONA"
                                              : "MODIFICA AREA",
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black54,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                        Text(
                                          widget.placeName,
                                          style: TextStyle(
                                            fontSize: titleFontSize,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF2D3142),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
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
                                    isSmallScreen
                                        ? "${_points.length} pts"
                                        : "${_points.length} punto/i",
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
                                Flexible(
                                  child: Text(
                                    _points.length >= 3
                                        ? "Area valida, trascina i punti."
                                        : "Tocca per creare almeno 3 vertici.",
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: _points.length >= 3
                                          ? Colors.green[700]
                                          : Colors.black54,
                                      fontWeight: _points.length >= 3
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),

                    // --- FABs (Pulsanti in basso) ---
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        SizedBox(
                          width: isSmallScreen ? 48 : 56,
                          height: isSmallScreen ? 48 : 56,
                          child: FloatingActionButton(
                            heroTag: "polySat",
                            backgroundColor: Colors.white,
                            onPressed: () =>
                                setState(() => _isSatellite = !_isSatellite),
                            child: Icon(
                                _isSatellite ? Icons.map : Icons.satellite_alt,
                                color: Colors.blue,
                                size: isSmallScreen ? 22 : 24),
                          ),
                        ),
                        Row(
                          children: [
                            if (_points.isNotEmpty)
                              _miniFAB(Icons.delete_sweep, Colors.redAccent,
                                  _clearAll, isSmallScreen, "polyClear"),
                            if (_points.isNotEmpty) const SizedBox(width: 8),
                            if (_points.isNotEmpty)
                              _miniFAB(Icons.undo, Colors.orange,
                                  _undoLastPoint, isSmallScreen, "polyUndo"),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: isSmallScreen ? 48 : 56,
                              height: isSmallScreen ? 48 : 56,
                              child: FloatingActionButton(
                                heroTag: "polySave",
                                backgroundColor: _points.length >= 3
                                    ? Colors.green
                                    : Colors.grey,
                                onPressed: _isSaving ? null : _savePolygon,
                                child: _isSaving
                                    ? const CircularProgressIndicator(
                                        color: Colors.white)
                                    : Icon(Icons.check,
                                        color: Colors.white,
                                        size: isSmallScreen ? 24 : 28),
                              ),
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
