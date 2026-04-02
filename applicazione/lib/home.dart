import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'dart:async';
import 'scambio.dart' as scambio;

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pet Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        primarySwatch: Colors.teal,
        useMaterial3: true,
      ),
      home: const PetTrackerNavigation(),
    );
  }
}

// --- LOGICA DI FORMATTAZIONE ---
String formattaUltimoAggiornamento(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return "N.D.";

  final oraAttuale = DateTime.now();
  final differenza = oraAttuale.difference(ultimoInvio);

  if (differenza.isNegative) {
    return "In tempo reale (${differenza.inSeconds}s)";
  }

  if (differenza.inSeconds < 60) {
    return "Adesso";
  } else if (differenza.inMinutes < 60) {
    return "${differenza.inMinutes} min fa";
  } else if (differenza.inHours < 24) {
    return "${differenza.inHours} h fa";
  } else if (differenza.inDays < 7) {
    return "${differenza.inDays} g fa";
  } else {
    return "${ultimoInvio.day}/${ultimoInvio.month}/${ultimoInvio.year}";
  }
}

Color getColoreStato(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return Colors.grey;
  final differenza = DateTime.now().difference(ultimoInvio);

  if (differenza.inMinutes < 30) return const Color(0xFF00C6B8);
  if (differenza.inMinutes < 60) return Colors.orange;
  return Colors.red;
}

class PetTrackerNavigation extends StatefulWidget {
  const PetTrackerNavigation({super.key});

  @override
  State<PetTrackerNavigation> createState() => _PetTrackerNavigationState();
}

class _PetTrackerNavigationState extends State<PetTrackerNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const PetTrackerDashboard(),
    const GeofencingScreen(),
    const BatteryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          selectedItemColor: const Color(0xFF00C6B8),
          unselectedItemColor: Colors.black26,
          showSelectedLabels: true,
          showUnselectedLabels: false,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.home_filled), label: "Home"),
            BottomNavigationBarItem(
                icon: Icon(Icons.map_rounded), label: "Mappa"),
            BottomNavigationBarItem(
                icon: Icon(Icons.battery_charging_full), label: "Energia"),
          ],
        ),
      ),
    );
  }
}

class PetTrackerDashboard extends StatefulWidget {
  const PetTrackerDashboard({super.key});

  @override
  State<PetTrackerDashboard> createState() => _PetTrackerDashboardState();
}

class _PetTrackerDashboardState extends State<PetTrackerDashboard> {
  late List<Map<String, String>> dates;
  late int selectedDateIndex;
  late String currentMonthName;

  DateTime? _ultimoAggiornamento;
  String _nomeZona = "Ricerca in corso...";
  bool _isLoading = true;

  StreamSubscription? _streamSubscription;
  Timer? _uiRefreshTimer;

  @override
  void initState() {
    super.initState();
    _initializeDates();

    _streamSubscription = scambio.posizioneStream.listen((nuovoRecord) async {
      try {
        String timeStr = nuovoRecord.getStringValue('timestamp');
        DateTime nuovoTempo = DateTime.parse(timeStr).toLocal();

        double petLat = nuovoRecord.getDoubleValue('lat');
        double petLon = nuovoRecord.getDoubleValue('lon');
        String nuovaZona = await _calcolaZonaDalPunto(LatLng(petLat, petLon));

        if (mounted) {
          setState(() {
            _ultimoAggiornamento = nuovoTempo;
            _nomeZona = nuovaZona;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint('❌ [HOME] Errore decodifica stream: $e');
      }
    });

    _scaricaDatiIniziali();

    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _scaricaDatiIniziali() async {
    final tempoIniziale = await scambio.getUltimoTimestamp();
    final zonaIniziale = await _calculateCurrentZone();

    if (mounted) {
      setState(() {
        _ultimoAggiornamento ??= tempoIniziale;
        if (_nomeZona == "Ricerca in corso...") {
          _nomeZona = zonaIniziale;
        }
        _isLoading = false;
      });
    }
  }

  Future<String> _calculateCurrentZone() async {
    if (!scambio.isReady) await scambio.autenticazione();
    try {
      final posResult = await scambio.pb
          .collection('positions_test')
          .getList(page: 1, perPage: 1, sort: '-timestamp');
      if (posResult.items.isEmpty) return "Posizione sconosciuta";

      final petLat = posResult.items.first.getDoubleValue('lat');
      final petLon = posResult.items.first.getDoubleValue('lon');
      return await _calcolaZonaDalPunto(LatLng(petLat, petLon));
    } catch (e) {
      return "Errore rilevamento";
    }
  }

  Future<String> _calcolaZonaDalPunto(LatLng petPos) async {
    try {
      final geoResult =
          await scambio.pb.collection('geofences_test').getFullList();

      for (var record in geoResult) {
        if (record.getBoolValue('is_active') == true) {
          List<LatLng> polygonPts = [];
          try {
            final rawList = record.getListValue<dynamic>('vertices');
            for (var pt in rawList) {
              if (pt is List && pt.length >= 2) {
                polygonPts.add(LatLng(double.parse(pt[0].toString()),
                    double.parse(pt[1].toString())));
              }
            }
          } catch (e) {
            continue;
          }

          if (polygonPts.length >= 3) {
            if (_isPointInsidePolygon(petPos, polygonPts)) {
              return record.getStringValue('name');
            }
          }
        }
      }
      return "Fuori zona sicura";
    } catch (e) {
      return "Errore rilevamento";
    }
  }

  bool _isPointInsidePolygon(LatLng point, List<LatLng> polygon) {
    bool isInside = false;
    int j = polygon.length - 1;

    for (int i = 0; i < polygon.length; i++) {
      final double xi = polygon[i].longitude;
      final double yi = polygon[i].latitude;
      final double xj = polygon[j].longitude;
      final double yj = polygon[j].latitude;

      final bool intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / (yj - yi) + xi);

      if (intersect) isInside = !isInside;
      j = i;
    }

    return isInside;
  }

  void _initializeDates() {
    DateTime today = DateTime.now();
    List<String> monthNames = [
      'Gennaio',
      'Febbraio',
      'Marzo',
      'Aprile',
      'Maggio',
      'Giugno',
      'Luglio',
      'Agosto',
      'Settembre',
      'Ottobre',
      'Novembre',
      'Dicembre'
    ];
    currentMonthName = monthNames[today.month - 1];
    List<String> weekDays = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];
    DateTime monday = today.subtract(Duration(days: today.weekday - 1));

    dates = List.generate(7, (index) {
      DateTime date = monday.add(Duration(days: index));
      return {
        'day': date.day.toString(),
        'weekDay': weekDays[date.weekday - 1],
      };
    });
    selectedDateIndex = today.weekday - 1;
  }

  @override
  Widget build(BuildContext context) {
    // Fattore di scala calcolato sull'altezza (l'emulatore base è ~800px)
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.65, 1.2);

    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.5,
              height: screenHeight * 0.18,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)]),
                borderRadius:
                    BorderRadius.only(bottomLeft: Radius.circular(100)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: 20 * scale, vertical: 10 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Spacer(flex: 1),

                  // 1. Intestazione Utente
                  Text('Bentornato,',
                      style: TextStyle(
                          fontSize: 16 * scale, color: Colors.black54)),
                  Text('Alberto Angela',
                      style: TextStyle(
                          fontSize: 30 * scale, fontWeight: FontWeight.bold)),

                  const Spacer(flex: 2),

                  // 2. Card Posizione
                  _buildPositionCard(scale),

                  const Spacer(flex: 2),

                  // 3. Intestazione Calendario
                  _buildMonthHeader(scale),

                  const Spacer(flex: 1),

                  // 4. Calendario
                  _buildHorizontalCalendar(scale),

                  const Spacer(flex: 2),

                  // 5. Intestazione Attività
                  Text("Attività Odierna",
                      style: TextStyle(
                          fontSize: 20 * scale, fontWeight: FontWeight.bold)),

                  const Spacer(flex: 1),

                  // 6. Statistiche
                  _buildActivityStats(scale),

                  const Spacer(flex: 2),

                  // 7. Pannello LoRaWAN
                  _buildLoraInfoPanel(_ultimoAggiornamento, scale),

                  const Spacer(flex: 1),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPositionCard(double scale) {
    return GestureDetector(
      onTap: () {
        final navState =
            context.findAncestorStateOfType<_PetTrackerNavigationState>();
        if (navState != null) {
          navState.setState(() => navState._currentIndex = 1);
        }
      },
      child: Container(
        padding: EdgeInsets.all(15 * scale),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20 * scale),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.location_on,
                color: const Color(0xFF00C6B8), size: 36 * scale),
            SizedBox(width: 15 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Posizione Attuale",
                      style: TextStyle(
                          color: Colors.black45, fontSize: 13 * scale)),
                  SizedBox(height: 4 * scale),
                  _isLoading
                      ? Text("Caricamento...",
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16 * scale,
                              color: Colors.grey))
                      : Text(_nomeZona,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16 * scale,
                              color: _nomeZona == "Fuori zona sicura"
                                  ? Colors.red
                                  : Colors.black)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios,
                color: Colors.black12, size: 16 * scale),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthHeader(double scale) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.calendar_month,
            color: const Color(0xFF00C6B8), size: 20 * scale),
        SizedBox(width: 8 * scale),
        Text(currentMonthName,
            style: TextStyle(
                fontSize: 18 * scale,
                color: Colors.black54,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildHorizontalCalendar(double scale) {
    return SizedBox(
      height: 85 * scale,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(dates.length, (index) {
          bool isSelected = index == selectedDateIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedDateIndex = index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: EdgeInsets.symmetric(horizontal: 3 * scale),
                decoration: BoxDecoration(
                  gradient: isSelected
                      ? const LinearGradient(
                          colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)])
                      : null,
                  color: isSelected ? null : Colors.white,
                  borderRadius: BorderRadius.circular(15 * scale),
                  boxShadow: isSelected
                      ? null
                      : [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.03),
                              blurRadius: 5)
                        ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(dates[index]['day']!,
                        style: TextStyle(
                            fontSize: 16 * scale,
                            fontWeight: FontWeight.bold,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF2D3142))),
                    SizedBox(height: 2 * scale),
                    Text(dates[index]['weekDay']!,
                        style: TextStyle(
                            fontSize: 11 * scale,
                            color:
                                isSelected ? Colors.white70 : Colors.black45)),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildActivityStats(double scale) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildStatCircle("Passi", "1.240", Icons.pets, Colors.orange, scale),
        _buildStatCircle("Km", "2.4", Icons.straighten, Colors.blue, scale),
        _buildStatCircle("Minuti", "45", Icons.timer, Colors.purple, scale),
      ],
    );
  }

  Widget _buildStatCircle(
      String label, String value, IconData icon, Color color, double scale) {
    double circleSize = 55 * scale;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: circleSize,
          height: circleSize,
          decoration: BoxDecoration(
              color: color.withOpacity(0.1), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: circleSize * 0.45),
        ),
        SizedBox(height: 8 * scale),
        Text(value,
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * scale)),
        Text(label,
            style: TextStyle(color: Colors.black38, fontSize: 12 * scale)),
      ],
    );
  }

  Widget _buildLoraInfoPanel(DateTime? ultimoInvio, double scale) {
    final coloreStato = getColoreStato(ultimoInvio);
    final testoTempo = formattaUltimoAggiornamento(ultimoInvio);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      width: double.infinity,
      padding:
          EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 15 * scale),
      decoration: BoxDecoration(
        color: coloreStato.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15 * scale),
        border: Border.all(color: coloreStato.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sync, color: coloreStato, size: 18 * scale),
          SizedBox(width: 8 * scale),
          Text(
            "Ultimo aggiornamento: $testoTempo",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: coloreStato.withOpacity(0.8),
              fontWeight: FontWeight.w600,
              fontSize: 13 * scale,
            ),
          ),
        ],
      ),
    );
  }
}
