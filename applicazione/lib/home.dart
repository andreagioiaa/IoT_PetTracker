import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:pet_tracker/repositories/activities_repo.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'tracking_screen.dart';
import 'dart:async';
import 'scambio.dart' as scambio;
import 'settings.dart';
import "repositories/positions_repo.dart";
import "repositories/users_repo.dart"; // Aggiunto import
import "objects/positions.dart"; // Aggiunto per il tipo Positions
import 'package:flutter_localizations/flutter_localizations.dart';

// --- VARIABILI GLOBALI DI STATO ---
final ValueNotifier<bool> isTrackingMode = ValueNotifier(false);
final ValueNotifier<int> geofenceUpdateSignal = ValueNotifier(0);
final ValueNotifier<String> mapFocusPreference = ValueNotifier('Animale');
final ValueNotifier<bool> hasLocationPermission = ValueNotifier(false);

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pet Tracker',
      debugShowCheckedModeBanner: false,
      // --- QUESTE RIGHE SONO FONDAMENTALI PER IL CALENDARIO ---
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('it', 'IT'), // Forza l'italiano come lingua
      ],
      // -------------------------------------------------------
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
  if (differenza.isNegative) return "Adesso";
  if (differenza.inSeconds < 60) return "Adesso";
  if (differenza.inMinutes < 60) return "${differenza.inMinutes} min fa";
  if (differenza.inHours < 24) return "${differenza.inHours} h fa";
  if (differenza.inDays < 7) return "${differenza.inDays} g fa";
  return "${ultimoInvio.day}/${ultimoInvio.month}/${ultimoInvio.year}";
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
    isTrackingMode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  List<Widget> get _currentScreens => [
        const PetTrackerDashboard(),
        isTrackingMode.value ? const TrackingScreen() : const GeofencingScreen(),
        const BatteryScreen(),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _currentScreens),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          selectedItemColor: const Color(0xFF00C6B8),
          unselectedItemColor: Colors.black26,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: "Home"),
            BottomNavigationBarItem(icon: Icon(Icons.map_rounded), label: "Mappa"),
            BottomNavigationBarItem(icon: Icon(Icons.battery_charging_full), label: "Energia"),
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
  // Repository
  final UsersRepository _usersRepo = UsersRepository();
  final PositionsRepository _positionsRepo = PositionsRepository(scambio.pb);

  // 1. Aggiungi il repository (assicurati di aver importato activities_repo.dart)
  final ActivitiesRepository _activitiesRepo = ActivitiesRepository(scambio.pb);

  // 2. Variabile per i dati aggregati da mostrare nella UI
  Map<String, dynamic> _dailyStats = {
    'steps': 0,
    'km': "0.0",
    'minutes': 0,
  };

  late List<Map<String, String>> dates;
  late int selectedDateIndex;
  late String currentMonthName;

  DateTime? _ultimoAggiornamento;
  String _nomeZona = "Ricerca in corso...";
  String _displayUsername = "Caricamento...";
  bool _isLoading = true;

  StreamSubscription? _streamSubscription;
  Timer? _uiRefreshTimer;

  @override
  void initState() {
    super.initState();
    _initializeDates();

    geofenceUpdateSignal.addListener(() async {
      if (_ultimoAggiornamento != null) {
        String nuovaZona = await _calculateCurrentZone();
        if (mounted) setState(() => _nomeZona = nuovaZona);
      }
    });

    // Sottoscrizione allo stream tipizzato
    _positionsRepo.subscribeToPositions();
    _streamSubscription = _positionsRepo.positionsStream.listen((nuovaPos) async {
      try {
        String nuovaZona = await _calcolaZonaDalPunto(LatLng(nuovaPos.lat, nuovaPos.lon));
        if (mounted) {
          setState(() {
            _ultimoAggiornamento = nuovaPos.timestamp;
            _nomeZona = nuovaZona;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint('❌ [HOME] Errore stream: $e');
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

  // Variabile per la data attualmente visualizzata (inizialmente oggi)
  DateTime _dataSelezionata = DateTime.now();

  // Metodo per inizializzare o aggiornare la riga dei giorni
  void _initializeDates({DateTime? riferimento}) {
    DateTime base = riferimento ?? DateTime.now();
    List<String> monthNames = ['Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno', 'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'];
    
    setState(() {
      currentMonthName = monthNames[base.month - 1];
      
      // Calcoliamo il lunedì della settimana che contiene la data 'base'
      DateTime lunedi = base.subtract(Duration(days: base.weekday - 1));
      
      List<String> weekDays = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];
      dates = List.generate(7, (index) {
        DateTime date = lunedi.add(Duration(days: index));
        return {'day': date.day.toString(), 'weekDay': weekDays[date.weekday - 1]};
      });
      
      // Il focus (cerchietto colorato) va sul giorno scelto
      selectedDateIndex = base.weekday - 1;
    });
  }

  // Funzione per il calendario che aggiorna anche la riga dei giorni
  Future<void> _selezionaData(BuildContext context) async {
    final DateTime? scelta = await showDatePicker(
      context: context,
      initialDate: _dataSelezionata,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      locale: const Locale('it', 'IT'),
    );

  if (scelta != null) {
    setState(() => _dataSelezionata = scelta);
    _initializeDates(riferimento: scelta); // RIGENERA la settimana
    _scaricaDatiAttivita(scelta); // Scarica i dati (passi, km, min) per quel giorno
  }
}


  Future<void> _scaricaDatiAttivita(DateTime data) async {
    setState(() => _isLoading = true); // Mostra un caricamento se vuoi

    try {
      // Recuperiamo l'ID della board (puoi prenderlo dall'utente o da una variabile globale)
      // Per ora ipotizziamo di avere il boardId salvato o recuperabile
      final String? boardId = scambio.pb.authStore.model?.id; // Verifica la tua logica di IDs
      
      if (boardId == null) return;

      // Chiamata al repository (metodo fetchActivitiesByDate aggiunto nel passaggio precedente)
      final attivita = await _activitiesRepo.fetchActivitiesByDate(boardId, data);

      int passiTotali = 0;
      Duration durataTotale = Duration.zero;

      for (var act in attivita) {
        passiTotali += act.totalSteps;

        if (act.startTime != null && act.endTime != null) {
          durataTotale += act.endTime!.difference(act.startTime!);
        } else if (act.isActive && act.startTime != null) {
          // Se l'attività è ancora in corso, calcoliamo fino ad ora
          durataTotale += DateTime.now().difference(act.startTime!);
        }
      }

      // Calcolo KM (falcata media 0.7m)
      double kmTotali = (passiTotali * 0.7) / 1000;

      if (mounted) {
        setState(() {
          _dailyStats = {
            'steps': passiTotali,
            'km': kmTotali.toStringAsFixed(1),
            'minutes': durataTotale.inMinutes,
          };
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("❌ Errore scaricamento attività: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _scaricaDatiIniziali() async {
    // 1. Dati Utente
    final user = await _usersRepo.getCurrentUser();
    final statoAllarme = await _usersRepo.getAlarmStatus();

    // 2. Dati Posizione
    final tempoIniziale = await _positionsRepo.getLastTimestamp();
    final zonaIniziale = await _calculateCurrentZone();

    if (mounted) {
      setState(() {
        _displayUsername = user?.username ?? 'username';
        if (statoAllarme != null) isTrackingMode.value = statoAllarme;
        _ultimoAggiornamento = tempoIniziale;
        _nomeZona = zonaIniziale;
        _isLoading = false;
      });
    }
  }

  Future<String> _calculateCurrentZone() async {
    try {
      final pos = await _positionsRepo.getLatestPosition(); //
      if (pos == null) return "Posizione sconosciuta";
      return await _calcolaZonaDalPunto(LatLng(pos.lat, pos.lon));
    } catch (e) {
      return "Errore rilevamento";
    }
  }

  Future<String> _calcolaZonaDalPunto(LatLng petPos) async {
    try {
      final geoResult = await scambio.pb.collection('geofences').getFullList();
      for (var record in geoResult) {
        if (record.getBoolValue('is_active') == true) {
          List<LatLng> polygonPts = [];
          final rawList = record.getListValue<dynamic>('vertices');
          for (var pt in rawList) {
            if (pt is List && pt.length >= 2) {
              polygonPts.add(LatLng(double.parse(pt[0].toString()), double.parse(pt[1].toString())));
            }
          }
          if (polygonPts.length >= 3 && _isPointInsidePolygon(petPos, polygonPts)) {
            return record.getStringValue('name');
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
      if (((polygon[i].latitude > point.latitude) != (polygon[j].latitude > point.latitude)) &&
          (point.longitude < (polygon[j].longitude - polygon[i].longitude) * (point.latitude - polygon[i].latitude) / (polygon[j].latitude - polygon[i].latitude) + polygon[i].longitude)) {
        isInside = !isInside;
      }
      j = i;
    }
    return isInside;
  }

  @override
  Widget build(BuildContext context) {
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
                gradient: LinearGradient(colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)]),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(100)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 10 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Spacer(flex: 1),
                  Text('Bentornato,', style: TextStyle(fontSize: 16 * scale, color: Colors.black54)),
                  Text(_displayUsername, style: TextStyle(fontSize: 25 * scale, fontWeight: FontWeight.bold)),
                  const Spacer(flex: 2),
                  ValueListenableBuilder<bool>(
                    valueListenable: isTrackingMode,
                    builder: (context, isTracking, child) {
                      String displayZone = _nomeZona;
                      Color zoneColor = Colors.black;
                      IconData locationIcon = Icons.location_on;
                      if (_nomeZona == "Fuori zona sicura") {
                        if (isTracking) {
                          displayZone = "ALLARME: È USCITO!";
                          zoneColor = Colors.red;
                          locationIcon = Icons.warning_rounded;
                        } else {
                          displayZone = "In passeggiata";
                          zoneColor = const Color(0xFF00C6B8);
                          locationIcon = Icons.directions_walk;
                        }
                      }
                      return Column(
                        children: [
                          _buildDynamicPositionCard(scale, displayZone, zoneColor, locationIcon),
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
          Positioned(
            top: 50 * scale,
            right: 20 * scale,
            child: IconButton(
              icon: const Icon(Icons.settings, color: Colors.white, size: 28),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => SettingsScreen(onProfileUpdated: () => _scaricaDatiIniziali())),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicPositionCard(double scale, String displayZone, Color zoneColor, IconData icon) {
    return GestureDetector(
      onTap: () {
        final navState = context.findAncestorStateOfType<_PetTrackerNavigationState>();
        if (navState != null) navState.setState(() => navState._currentIndex = 1);
      },
      child: Container(
        padding: EdgeInsets.all(15 * scale),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20 * scale),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
        ),
        child: Row(
          children: [
            Icon(icon, color: zoneColor == Colors.black ? const Color(0xFF00C6B8) : zoneColor, size: 36 * scale),
            SizedBox(width: 15 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Posizione Attuale", style: TextStyle(color: Colors.black45, fontSize: 13 * scale)),
                  SizedBox(height: 4 * scale),
                  _isLoading
                      ? Text("Caricamento...", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * scale, color: Colors.grey))
                      : Text(displayZone, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * scale, color: zoneColor)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.black12, size: 16 * scale),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingToggle(double scale, bool isActive) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 15 * scale, vertical: 5 * scale),
      decoration: BoxDecoration(
          color: isActive ? Colors.red.withOpacity(0.08) : const Color(0xFF00C6B8).withOpacity(0.08),
          borderRadius: BorderRadius.circular(15 * scale),
          border: Border.all(color: isActive ? Colors.red.withOpacity(0.3) : const Color(0xFF00C6B8).withOpacity(0.3))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(isActive ? Icons.verified_user : Icons.remove_moderator, color: isActive ? Colors.red : const Color(0xFF00C6B8), size: 24 * scale),
              SizedBox(width: 10 * scale),
              Text(isActive ? "Allarme Antifuga ATTIVO" : "Allarme Antifuga SPENTO",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * scale, color: isActive ? Colors.red : const Color(0xFF00C6B8))),
            ],
          ),
          Switch(
            value: isActive,
            activeColor: Colors.red,
            onChanged: (val) async {
              isTrackingMode.value = val;
              bool successo = await _usersRepo.updateAlarm(val); //
              if (!successo) {
                isTrackingMode.value = !val;
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Errore sincronizzazione allarme")));
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
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 15)],
      ),
      child: Column(
        children: [
          // HEADER UNICO: Titolo + Icona Calendario Cliccabile
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Attività di $currentMonthName", 
                  style: TextStyle(fontSize: 16 * scale, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.calendar_month, color: Color(0xFF00C6B8)),
                onPressed: () => _selezionaData(context), // Apre il calendario senza crash
              ),
            ],
          ),
          SizedBox(height: 16 * scale),
          // RIGA DEI GIORNI (La settimana che era sparita)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(dates.length, (index) {
              bool isSelected = index == selectedDateIndex;
              return GestureDetector(
                onTap: () {
                  // Se clicchi un giorno della settimana mostrata
                  DateTime baseSettimana = _dataSelezionata.subtract(Duration(days: _dataSelezionata.weekday - 1));
                  DateTime giornoCliccato = baseSettimana.add(Duration(days: index));
                  
                  setState(() {
                    selectedDateIndex = index;
                    _dataSelezionata = giornoCliccato;
                  });
                  _scaricaDatiAttivita(giornoCliccato);
                },
                child: Container(
                  width: 40 * scale,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF00C6B8) : Colors.transparent, 
                    borderRadius: BorderRadius.circular(12)
                  ),
                  child: Column(
                    children: [
                      Text(dates[index]['weekDay']![0], 
                          style: TextStyle(color: isSelected ? Colors.white70 : Colors.black38)),
                      Text(dates[index]['day']!, 
                          style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? Colors.white : Colors.black87)),
                    ],
                  ),
                ),
              );
            }),
          ),
          const Divider(height: 24),
          // STATISTICHE (Passi, Km, Minuti)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildCompactStat("Passi", "${_dailyStats['steps']}", Icons.pets, Colors.orange, scale),
              _buildCompactStat("Km", "${_dailyStats['km']}", Icons.straighten, Colors.blue, scale),
              _buildCompactStat("Minuti", "${_dailyStats['minutes']}", Icons.timer, Colors.purple, scale),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompactStat(String label, String value, IconData icon, Color color, double scale) {
    return Column(
      children: [
        CircleAvatar(backgroundColor: color.withOpacity(0.1), radius: 18 * scale, child: Icon(icon, color: color, size: 20 * scale)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.black38, fontSize: 10)),
      ],
    );
  }

  Widget _buildLoraInfoPanel(DateTime? ultimoInvio, double scale) {
    final coloreStato = getColoreStato(ultimoInvio);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: coloreStato.withOpacity(0.1), borderRadius: BorderRadius.circular(15), border: Border.all(color: coloreStato.withOpacity(0.3))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sync, color: coloreStato, size: 18 * scale),
          const SizedBox(width: 8),
          Text("Ultimo aggiornamento: ${formattaUltimoAggiornamento(ultimoInvio)}", style: TextStyle(color: coloreStato, fontWeight: FontWeight.bold, fontSize: 13 * scale)),
        ],
      ),
    );
  }
}