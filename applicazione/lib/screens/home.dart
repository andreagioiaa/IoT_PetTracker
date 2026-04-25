import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/cupertino.dart';
import 'package:pet_tracker/repositories/activities_repo.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'tracking.dart';
import 'dart:async';
import '../services/authentication.dart' as scambio;
import '../services/position_gps.dart';
import 'settings.dart';
import "../repositories/positions_repo.dart";
import "../repositories/users_repo.dart";
import 'package:shared_preferences/shared_preferences.dart';
import "daily_recap.dart";
import 'package:intl/intl.dart';

// --- VARIABILI GLOBALI DI STATO ---
final ValueNotifier<bool> isTrackingMode = ValueNotifier(false);
final ValueNotifier<int> geofenceUpdateSignal = ValueNotifier(0);
final ValueNotifier<String> mapFocusPreference = ValueNotifier('Animale');

// Funzione globale da chiamare all'avvio dell'app (es. nel main o in initState di PetTrackerApp)
Future<void> loadMapPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  final String savedFocus = prefs.getString('map_focus_priority') ?? 'Animale';
  mapFocusPreference.value = savedFocus;
}

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pet Tracker',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('it', 'IT'), // Forza l'italiano come lingua
      ],
      locale: const Locale('it', 'IT'),
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

String formattaUltimoAggiornamento(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return "N.D.";

  final oraLocale = DateTime.now();

  // Se il dato è nel futuro (es. -69 min), sappiamo che Flutter ha aggiunto 2 ore di troppo.
  // Sottraiamo 2 ore per tornare all'orario reale della board.
  DateTime dataReale = ultimoInvio;
  if (oraLocale.difference(ultimoInvio).inMinutes < -30) {
    dataReale = ultimoInvio.subtract(const Duration(hours: 2));
  }

  final differenza = oraLocale.difference(dataReale);

  if (differenza.isNegative) return "Adesso";
  if (differenza.inSeconds < 60) return "Adesso";
  if (differenza.inMinutes < 60) return "${differenza.inMinutes} min fa";
  if (differenza.inHours < 24) return "${differenza.inHours} ore fa";

  return "${dataReale.day}/${dataReale.month}/${dataReale.year}";
}

Color getColoreStato(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return Colors.grey;

  // FIX: Anche qui serve la conversione locale per non avere colori errati
  final differenza = DateTime.now().difference(ultimoInvio.toLocal());

  if (differenza.inMinutes < 30) return const Color(0xFF00C6B8);
  if (differenza.inMinutes < 60) return Colors.orange;
  return Colors.red;
}

class PetTrackerNavigation extends StatefulWidget {
  final Map<String, dynamic>? preloadedData; // Aggiungi questo
  const PetTrackerNavigation({super.key, this.preloadedData});

  @override
  State<PetTrackerNavigation> createState() => _PetTrackerNavigationState();
}

class _PetTrackerNavigationState extends State<PetTrackerNavigation> {
  int _currentIndex = 0;

  List<Widget> get _currentScreens => [
        PetTrackerDashboard(preloadedData: widget.preloadedData),
        isTrackingMode.value
            ? const TrackingScreen()
            : const GeofencingScreen(),
        const BatteryScreen(),
      ];

  @override
  void initState() {
    super.initState();
    isTrackingMode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _currentScreens),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          selectedItemColor: const Color(0xFF00C6B8),
          unselectedItemColor: Colors.black26,
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
  final Map<String, dynamic>? preloadedData;
  const PetTrackerDashboard({super.key, this.preloadedData});

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

  bool _isLoading = true; // Per il caricamento iniziale di tutta la pagina
  bool _isActivityLoading = false; // Per il passaggio tra i giorni

  StreamSubscription? _streamSubscription;
  Timer? _uiRefreshTimer;

  @override
  void initState() {
    super.initState();

    // 1. Inizializzazione UI (Date e Calendario)
    _initializeDates();

    // 2. INIEZIONE DATI PRE-CARICATI (Dalla Splash)
    // Questo elimina il testo "Caricamento..." istantaneamente se i dati ci sono
    if (widget.preloadedData != null) {
      _displayUsername = widget.preloadedData!['username'];
      isTrackingMode.value = widget.preloadedData!['alarm'];
      _nomeZona = widget.preloadedData!['zone'];

      final pos = widget.preloadedData!['lastPosition'];
      if (pos != null) _ultimoAggiornamento = pos.timestamp;

      if (widget.preloadedData!['activities'] != null) {
        _elaboraAttivita(widget.preloadedData!['activities']);
      }

      _isLoading = false; // Fermiamo il caricamento UI subito!
    } else {
      // Fallback: se la Splash fallisce, carichiamo i dati qui (vecchio metodo)
      _scaricaDatiIniziali();
    }

    // 3. LOGICA DI SISTEMA (Permessi e Notifiche)
    // Usiamo Future.microtask per assicurarci che il context sia pronto per l'eventuale pop-up
    Future.microtask(() => PositionGpsService.richiediPermessi(context));

    // 4. ASCOLTATORI (Listeners)
    // Reagisce quando cambi le impostazioni dei Geofence
    geofenceUpdateSignal.addListener(() async {
      if (_ultimoAggiornamento != null) {
        String nuovaZona = await _calculateCurrentZone();
        if (mounted) setState(() => _nomeZona = nuovaZona);
      }
    });

    // 5. STREAM REAL-TIME (Posizione Animale)
    // Anche se abbiamo i dati della Splash, dobbiamo ascoltare i nuovi movimenti!
    _positionsRepo.subscribeToPositions();
    _streamSubscription =
        _positionsRepo.positionsStream.listen((nuovaPos) async {
      try {
        // Usiamo il metodo del repository per mantenere pulita la UI
        String nuovaZona = await PositionGpsService.calcolaZonaDalPunto(
            LatLng(nuovaPos.lat, nuovaPos.lon));
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

    // 6. TIMER DI AGGIORNAMENTO UI
    // Aggiorna il testo "X min fa" ogni 30 secondi
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

  void _elaboraAttivita(List<dynamic> attivita) {
    int passiTotali = 0;
    Duration durataTotale = Duration.zero;

    for (var act in attivita) {
      passiTotali += (act.totalSteps as int);
      if (act.startTime != null && act.endTime != null) {
        durataTotale += act.endTime!.difference(act.startTime!);
      }
    }

    double kmTotali = (passiTotali * 0.7) / 1000;

    if (mounted) {
      setState(() {
        _dailyStats = {
          'steps': passiTotali,
          'km': kmTotali.toStringAsFixed(1),
          'minutes': durataTotale.inMinutes,
        };
      });
    }
  }

  // Variabile per la data attualmente visualizzata (inizialmente oggi)
  DateTime _dataSelezionata = DateTime.now();

  // Metodo per inizializzare o aggiornare la riga dei giorni
  void _initializeDates({DateTime? riferimento}) {
    DateTime base = riferimento ?? DateTime.now();
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

    setState(() {
      currentMonthName = monthNames[base.month - 1];

      // Calcoliamo il lunedì della settimana che contiene la data 'base'
      DateTime lunedi = base.subtract(Duration(days: base.weekday - 1));

      List<String> weekDays = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];
      dates = List.generate(7, (index) {
        DateTime date = lunedi.add(Duration(days: index));
        return {
          'day': date.day.toString(),
          'weekDay': weekDays[date.weekday - 1]
        };
      });

      // Il focus (cerchietto colorato) va sul giorno scelto
      selectedDateIndex = base.weekday - 1;
    });
  }

  void _selezionaData(BuildContext context, double scale) {
    // Variabile temporanea per salvare la data mentre l'utente gira la ruota
    DateTime tempPickedDate = _dataSelezionata;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height *
              0.40, // Altezza ridotta per il picker
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
          ),
          child: Column(
            children: [
              // --- HEADER: Annulla | Modifica giorni | Salva ---
              Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: 20 * scale, vertical: 15 * scale),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Text(
                        "Annulla",
                        style: TextStyle(
                          fontSize: 16 * scale,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                    Text(
                      "Seleziona Data",
                      style: TextStyle(
                        fontSize: 18 * scale,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context); // Chiude il modale
                        // Applica la data scelta e aggiorna i dati nella Home
                        if (mounted) {
                          setState(() {
                            _dataSelezionata = tempPickedDate;
                          });
                          _scaricaDatiAttivita(_dataSelezionata);
                        }
                      },
                      child: Text(
                        "Salva",
                        style: TextStyle(
                          fontSize: 16 * scale,
                          fontWeight: FontWeight.bold,
                          color:
                              const Color(0xFF00C6B8), // Il teal della tua app
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Divider(height: 1, color: Colors.grey[300]),

              // --- PICKER A RUOTA STILE iOS ---
              Expanded(
                child: Localizations.override(
                  context: context,
                  locale: const Locale('it', 'IT'),
                  delegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  child: CupertinoTheme(
                    data: const CupertinoThemeData(
                      textTheme: CupertinoTextThemeData(
                        dateTimePickerTextStyle: TextStyle(
                          color: Colors.black87,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.date,
                      initialDateTime: _dataSelezionata,
                      maximumDate: DateTime.now(),
                      minimumDate: DateTime(2020),
                      dateOrder: DatePickerDateOrder.dmy,
                      onDateTimeChanged: (DateTime newDate) {
                        tempPickedDate = newDate;
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> caricaPreferenzeMappa() async {
    final prefs = await SharedPreferences.getInstance();
    final String? focusSalvato = prefs.getString('map_focus_priority');
    if (focusSalvato != null) {
      mapFocusPreference.value = focusSalvato;
    }
  }

  Future<void> _scaricaDatiAttivita(DateTime data) async {
    // Usiamo la variabile specifica, non quella globale della pagina
    setState(() => _isActivityLoading = true);

    try {
      // 1. Recuperiamo il boardId interrogando la collezione 'boards'
      final String? boardId = await _usersRepo.getBoardIdFromBoards();

      if (boardId == null || boardId.isEmpty) {
        debugPrint(
            "⚠️ Nessuna board trovata per questo account nella collezione 'boards'.");
        if (mounted) setState(() => _isActivityLoading = false);
        return;
      }

      // 2. Procediamo con il recupero delle attività usando l'ID trovato
      final attivita =
          await _activitiesRepo.fetchActivitiesByDate(boardId, data);

      int passiTotali = 0;
      Duration durataTotale = Duration.zero;

      for (var act in attivita) {
        passiTotali += act.totalSteps;
        if (act.startTime != null && act.endTime != null) {
          durataTotale += act.endTime!.difference(act.startTime!);
        } else if (act.isActive && act.startTime != null) {
          durataTotale += DateTime.now().difference(act.startTime!);
        }
      }

      double kmTotali = (passiTotali * 0.7) / 1000;

      if (mounted) {
        setState(() {
          _dailyStats = {
            'steps': passiTotali,
            'km': kmTotali.toStringAsFixed(1),
            'minutes': durataTotale.inMinutes,
          };
          _isActivityLoading = false; // Fine caricamento specifico
        });
      }
    } catch (e) {
      debugPrint("❌ Errore scaricamento attività: $e");
      if (mounted) setState(() => _isActivityLoading = false);
    }
  }

  String _formattaTempo(int minutiTotali) {
    if (minutiTotali == 0) return "0 min";
    if (minutiTotali < 60) return "$minutiTotali min";

    final int ore = minutiTotali ~/ 60; // Divide e prende solo l'intero
    final int minuti = minutiTotali % 60; // Prende il resto (i minuti)

    if (minuti == 0) {
      return "${ore}h"; // Es: "2h"
    } else {
      return "${ore}h ${minuti}m"; // Es: "1h 30m"
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
      final pos = await _positionsRepo.getLatestPosition();
      if (pos == null) return "Posizione sconosciuta";
      return await PositionGpsService.calcolaZonaDalPunto(
          LatLng(pos.lat, pos.lon));
    } catch (e) {
      return "Errore rilevamento";
    }
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
                  Text('Bentornato,',
                      style: TextStyle(
                          fontSize: 16 * scale, color: Colors.black54)),
                  Text(_displayUsername,
                      style: TextStyle(
                          fontSize: 25 * scale, fontWeight: FontWeight.bold)),
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
          Positioned(
            top: 50 * scale,
            right: 20 * scale,
            child: IconButton(
              icon: const Icon(Icons.settings, color: Colors.white, size: 28),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => SettingsScreen(
                          onProfileUpdated: () => _scaricaDatiIniziali())),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicPositionCard(
      double scale, String displayZone, Color zoneColor, IconData icon) {
    return GestureDetector(
      onTap: () {
        final navState =
            context.findAncestorStateOfType<_PetTrackerNavigationState>();
        if (navState != null)
          navState.setState(() => navState._currentIndex = 1);
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
          Switch(
            value: isActive,
            activeColor: Colors.red,
            onChanged: (val) async {
              isTrackingMode.value = val;
              bool successo = await _usersRepo.updateAlarm(val); //
              if (!successo) {
                isTrackingMode.value = !val;
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text("Errore sincronizzazione allarme")));
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUnifiedActivityCard(double scale) {
    // Formattazione data (iniziale maiuscola per un look più pulito)
    String dataFormattata =
        DateFormat('EEEE d MMMM yyyy', 'it_IT').format(_dataSelezionata);
    dataFormattata =
        dataFormattata[0].toUpperCase() + dataFormattata.substring(1);

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24 * scale),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 15)
        ],
      ),
      child: Column(
        children: [
          // --- HEADER CON FRECCE E PILLOLA DATA ---
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Freccia Sinistra (giorno precedente)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(50),
                  onTap: _isActivityLoading
                      ? null
                      : () {
                          setState(() {
                            _dataSelezionata = _dataSelezionata
                                .subtract(const Duration(days: 1));
                          });
                          _scaricaDatiAttivita(_dataSelezionata);
                        },
                  child: Padding(
                    padding: EdgeInsets.all(8.0 * scale),
                    child: Icon(Icons.chevron_left,
                        color: Colors.black54, size: 28 * scale),
                  ),
                ),
              ),

              // Pulsante "Pillola" centrale con la data
              Expanded(
                child: GestureDetector(
                  onTap: () =>
                      _selezionaData(context, scale), // Passiamo lo scale!
                  child: Container(
                    margin: EdgeInsets.symmetric(horizontal: 4 * scale),
                    padding: EdgeInsets.symmetric(
                        vertical: 8 * scale, horizontal: 12 * scale),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C6B8).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20 * scale),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.calendar_today,
                            size: 14 * scale, color: const Color(0xFF009B90)),
                        SizedBox(width: 8 * scale),
                        Flexible(
                          child: Text(
                            dataFormattata,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13 * scale,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF009B90),
                            ),
                          ),
                        ),
                        SizedBox(width: 4 * scale),
                        Icon(Icons.arrow_drop_down,
                            size: 18 * scale, color: const Color(0xFF009B90)),
                      ],
                    ),
                  ),
                ),
              ),

              // Freccia Destra (giorno successivo)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(50),
                  onTap: _isActivityLoading
                      ? null
                      : () {
                          setState(() {
                            _dataSelezionata =
                                _dataSelezionata.add(const Duration(days: 1));
                          });
                          _scaricaDatiAttivita(_dataSelezionata);
                        },
                  child: Padding(
                    padding: EdgeInsets.all(8.0 * scale),
                    child: Icon(Icons.chevron_right,
                        color: Colors.black54, size: 28 * scale),
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 20 * scale),

          // --- SEZIONE STATISTICHE (CON CARICAMENTO ISOLATO) ---
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _isActivityLoading
                ? SizedBox(
                    key: const ValueKey('loading'),
                    height: 65 * scale,
                    child: const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF00C6B8)),
                      ),
                    ),
                  )
                : Row(
                    key: const ValueKey('data'),
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildCompactStat("Passi", "${_dailyStats['steps']}",
                          Icons.pets, Colors.orange, scale),
                      _buildCompactStat("Km", "${_dailyStats['km']}",
                          Icons.straighten, Colors.blue, scale),
                      _buildCompactStat(
                          "Durata",
                          _formattaTempo(_dailyStats['minutes']
                              as int), // Usa la nuova funzione
                          Icons.timer,
                          Colors.purple,
                          scale),
                    ],
                  ),
          ),

          SizedBox(height: 24 * scale),

          // --- PULSANTE "VEDI RESOCONTO TOTALE" ---
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        RecapScreen(dataSelezionata: _dataSelezionata),
                  ),
                );
              },
              icon: Icon(
                Icons
                    .format_list_bulleted_rounded, // Un'icona che richiama un elenco di attività
                size: 20 * scale,
                color: const Color(0xFF009B90), // Verde scuro per contrasto
              ),
              label: Text(
                "VEDI DETTAGLI ATTIVITÀ",
                style: TextStyle(
                  color: const Color(0xFF009B90),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  fontSize: 13 * scale,
                ),
              ),
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: const Color(0xFF00C6B8).withOpacity(0.1),
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16 * scale),
                ),
                padding: EdgeInsets.symmetric(vertical: 14 * scale),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactStat(
      String label, String value, IconData icon, Color color, double scale) {
    return Column(
      children: [
        CircleAvatar(
            backgroundColor: color.withOpacity(0.1),
            radius: 18 * scale,
            child: Icon(icon, color: color, size: 20 * scale)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.black38, fontSize: 10)),
      ],
    );
  }

  Widget _buildLoraInfoPanel(DateTime? ultimoInvio, double scale) {
    final coloreStato = getColoreStato(ultimoInvio);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
          color: coloreStato.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: coloreStato.withOpacity(0.3))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sync, color: coloreStato, size: 18 * scale),
          const SizedBox(width: 8),
          Text(
              "Ultimo aggiornamento: ${formattaUltimoAggiornamento(ultimoInvio)}",
              style: TextStyle(
                  color: coloreStato,
                  fontWeight: FontWeight.bold,
                  fontSize: 13 * scale)),
        ],
      ),
    );
  }
}
