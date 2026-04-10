import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'tracking_screen.dart'; // <-- LA TUA NUOVA PAGINA
import 'dart:async';
import 'scambio.dart' as scambio;
import 'settings.dart';

// --- VARIABILE GLOBALE PER IL TASTO ALLARME ---
final ValueNotifier<bool> isTrackingMode = ValueNotifier(false);

// --- VARIABILE GLOBALE PER AGGIORNARE LE ZONE ---
final ValueNotifier<int> geofenceUpdateSignal = ValueNotifier(0);

// --- VARIABILE GLOBALE PER ZONA DI ZOOM GEOFENCE PREFERITA ---
final ValueNotifier<String> mapFocusPreference = ValueNotifier('Animale');

// --- VARIABILE GLOBALE PER GESTIONE PERMESSI ---
final ValueNotifier<bool> hasLocationPermission = ValueNotifier(false);

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

  @override
  void initState() {
    super.initState();
    // Ascolta l'interruttore: se cambia, ricostruisce il menu in basso!
    isTrackingMode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  // Questa lista ora è "dinamica": cambia la pagina centrale in base al bottone!
  List<Widget> get _currentScreens => [
        const PetTrackerDashboard(),
        isTrackingMode.value
            ? const TrackingScreen()
            : const GeofencingScreen(),
        const BatteryScreen(),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _currentScreens,
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

    // Ricalcola la zona se le impostazioni del geofencing vengono modificate
    geofenceUpdateSignal.addListener(() async {
      // Usa l'ultima posizione nota per ricalcolare
      if (_ultimoAggiornamento != null) {
        String nuovaZona = await _calculateCurrentZone();
        if (mounted) {
          setState(() {
            _nomeZona = nuovaZona;
          });
        }
      }
    });

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

  String _nomeCompleto = "Caricamento..."; // Sostituisce il placeholder

  Future<void> _scaricaDatiIniziali() async {
    // 1. Recuperiamo nome e cognome
    final nomeIniziale = await scambio.getNomeCompleto();
    
    // 2. Recuperiamo lo stato dell'allarme dal database
    final statoAllarme = await scambio.getAllarme();

    if (mounted) {
      setState(() {
        _nomeCompleto = nomeIniziale;
        // Sincronizziamo il ValueNotifier globale con il database
        if (statoAllarme != null) {
          isTrackingMode.value = statoAllarme;
        }
      });
    }

    // Logica pre-esistente per timestamp e zona
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
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.65, 1.2);

    return Scaffold(
      body: Stack(
        children: [
          // Sfondo gradiente
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.5,
              height: screenHeight * 0.18,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)]),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(100)),
              ),
            ),
          ),
          
          // ⚙️ ICONA INGRANAGGIO (Posizionata sopra il gradiente)
          Positioned(
            top: 50 * scale,
            right: 20 * scale,
            child: IconButton(
              icon: const Icon(Icons.settings, color: Colors.white, size: 28),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true, // Necessario per l'altezza personalizzata
                  backgroundColor: Colors.transparent, // Permette di vedere i bordi arrotondati
                  builder: (context) => SettingsModal(
                    onProfileUpdated: () => _scaricaDatiIniziali(),
                  ),
                );
              },
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

                  Text('Bentornato,',
                      style: TextStyle(fontSize: 16 * scale, color: Colors.black54)),
                  Text(_nomeCompleto, // <-- VARIABILE DINAMICA
                      style: TextStyle(fontSize: 30 * scale, fontWeight: FontWeight.bold)),

                  const Spacer(flex: 2),

                  // Qui usiamo il ValueListenableBuilder per ascoltare l'interruttore
                  ValueListenableBuilder<bool>(
                    valueListenable: isTrackingMode,
                    builder: (context, isTracking, child) {
                      String displayZone = _nomeZona;
                      Color zoneColor = Colors.black;
                      IconData locationIcon = Icons.location_on;

                      // --- LA TUA LOGICA CUSTOM SULLA POSIZIONE ---
                      if (_nomeZona == "Fuori zona sicura") {
                        if (isTracking) {
                          displayZone = "ALLARME: È USCITO!";
                          zoneColor = Colors.red;
                          locationIcon = Icons.warning_rounded;
                        } else {
                          displayZone = "In passeggiata";
                          zoneColor =
                              const Color(0xFF00C6B8); // O verde se preferisci
                          locationIcon = Icons.directions_walk;
                        }
                      } else {
                        // Se è dentro casa, colore normale
                        zoneColor = Colors.black;
                      }

                      return Column(
                        children: [
                          _buildDynamicPositionCard(
                              scale, displayZone, zoneColor, locationIcon),
                          SizedBox(height: 15 * scale),
                          _buildTrackingToggle(scale, isTracking),
                        ],
                      );
                    },
                  ),

                  const Spacer(flex: 2),

                  _buildUnifiedActivityCard(scale),

                  const Spacer(flex: 2),

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

  // Card posizione modificata per ricevere il testo "dinamico" calcolato sopra
  Widget _buildDynamicPositionCard(
      double scale, String displayZone, Color zoneColor, IconData icon) {
    return GestureDetector(
      onTap: () {
        // Ora il bottone naviga SEMPRE alla tab 1 (Mappa).
        // Ma siccome la tab 1 cambia in base al toggle, l'effetto è perfetto!
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
            Icon(icon,
                color: zoneColor == Colors.black
                    ? const Color(0xFF00C6B8)
                    : zoneColor,
                size: 36 * scale),
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
                      : Text(displayZone,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16 * scale,
                              color: zoneColor)),
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

  // --- IL TUO NUOVO TASTO ON/OFF ---
  Widget _buildTrackingToggle(double scale, bool isActive) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 15 * scale, vertical: 5 * scale),
      decoration: BoxDecoration(
          color: isActive
              ? Colors.red.withOpacity(0.08)
              : const Color(0xFF00C6B8).withOpacity(0.08),
          borderRadius: BorderRadius.circular(15 * scale),
          border: Border.all(
              color: isActive
                  ? Colors.red.withOpacity(0.3)
                  : const Color(0xFF00C6B8).withOpacity(0.3))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(isActive ? Icons.verified_user : Icons.remove_moderator,
                  color: isActive ? Colors.red : const Color(0xFF00C6B8),
                  size: 24 * scale),
              SizedBox(width: 10 * scale),
              Text(
                  isActive
                      ? "Allarme Antifuga ATTIVO"
                      : "Allarme Antifuga SPENTO",
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14 * scale,
                      color: isActive ? Colors.red : const Color(0xFF00C6B8))),
            ],
          ),
          // All'interno di _buildTrackingToggle in home.dart
          Switch(
            value: isActive,
            activeColor: Colors.red,
            onChanged: (val) async {
              // 1. Aggiorniamo prima la UI locale per fluidità
              isTrackingMode.value = val;
              
              // 2. Inviato il comando a PocketBase
              bool successo = await scambio.setAllarme(val);
              
              if (!successo) {
                // Se il server fallisce, torniamo indietro e avvisiamo
                isTrackingMode.value = !val;
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Errore sincronizzazione allarme"))
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUnifiedActivityCard(double scale) {
    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24 * scale),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 15,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Attività di $currentMonthName",
                style: TextStyle(
                  fontSize: 16 * scale,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              Icon(Icons.calendar_month,
                  size: 20 * scale, color: const Color(0xFF00C6B8)),
            ],
          ),
          SizedBox(height: 16 * scale),
          SizedBox(
            height: 70 * scale,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(dates.length, (index) {
                bool isSelected = index == selectedDateIndex;
                return GestureDetector(
                  onTap: () => setState(() => selectedDateIndex = index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 40 * scale,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF00C6B8)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12 * scale),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          dates[index]['weekDay']![0],
                          style: TextStyle(
                            fontSize: 12 * scale,
                            color: isSelected ? Colors.white70 : Colors.black38,
                          ),
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          dates[index]['day']!,
                          style: TextStyle(
                            fontSize: 14 * scale,
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(vertical: 12 * scale),
            child: Divider(color: Colors.grey.withOpacity(0.1), thickness: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildCompactStat(
                  "Passi", "1.240", Icons.pets, Colors.orange, scale),
              _buildCompactStat(
                  "Km", "2.4", Icons.straighten, Colors.blue, scale),
              _buildCompactStat(
                  "Minuti", "45", Icons.timer, Colors.purple, scale),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompactStat(
      String label, String value, IconData icon, Color color, double scale) {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.all(8 * scale),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20 * scale),
        ),
        SizedBox(height: 6 * scale),
        Text(value,
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * scale)),
        Text(label,
            style: TextStyle(color: Colors.black38, fontSize: 11 * scale)),
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
