import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:pet_tracker/repositories/activities_repo.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'tracking.dart';
import 'dart:async';
import '../services/authentication.dart' as scambio;
import '../services/notification.dart';
import '../services/position_gps.dart';
import 'settings.dart';
import './globals/app_state.dart';
import "../repositories/positions_repo.dart";
import "../repositories/users_repo.dart";
import 'package:shared_preferences/shared_preferences.dart';
import "daily_recap.dart";
import 'package:intl/intl.dart';
import 'splash_view.dart';
import "../services/util.dart";

// Funzione globale da chiamare all'avvio dell'app (es. nel main o in initState di PetTrackerApp)
Future<void> loadMapPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  final String savedFocus = prefs.getString('map_focus_priority') ?? 'Animale';
  mapFocusPreference.value = savedFocus;
}

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  @override
  Widget build(BuildContext context) {
    // Controllo se l'utente ha già fatto il login in passato
    bool isAuth = scambio.pb.authStore.isValid;

    return MaterialApp(
      title: 'Pet Tracker',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('it', 'IT'),
      ],
      locale: const Locale('it', 'IT'),
      theme: ThemeData(
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        primarySwatch: Colors.teal,
        useMaterial3: true,
      ),

      // L'app DEVE partire dalla Splash per scaricare i dati, senza far vedere il caricamento
      home: SplashScreen(isAlreadyAuthenticated: isAuth),
    );
  }
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

    // Impostiamo il valore dell'allarme PRIMA di costruire la UI
    if (widget.preloadedData != null) {
      isTrackingMode.value = widget.preloadedData!['alarm'] ?? false;
    }

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

  // Sostituisci _nomeZona con questa variabile
  Map<String, dynamic> _configZona = {
    'titolo': 'Ricerca in corso...',
    'colore': Colors.grey,
    'icona': Icons.location_on
  };

  String _displayUsername = "Caricamento...";

  // Per il caricamento iniziale di tutta la pagina
  bool _isLoading = true;

  // Data di default (fallback)
  DateTime _minDataSelezionabile = DateTime(2024);

  // Per il passaggio tra i giorni
  bool _isActivityLoading = false;

  StreamSubscription? _streamSubscription;
  Timer? _uiRefreshTimer;

  String? _currentBoardRecordId; // Salviamo l'ID interno di PocketBase

  String _currentStatus =
      'n'; // Variabile locale per lo stato attività (n, s, p)

  @override
  void initState() {
    super.initState();
    _initializeDates();
    _recuperaDataCreazioneBoard();

    // Caricamento dati e attivazione ascoltatori
    _scaricaDatiIniziali();
    _attivaRealTimeStatus(); // Nuova funzione per la reattività dello status

    // 3. INIEZIONE DATI PRE-CARICATI (Dalla Splash)
    // Questo elimina il testo "Caricamento..." istantaneamente se i dati ci sono
    if (widget.preloadedData != null) {
      _displayUsername = widget.preloadedData!['username'];

      // Estraiamo la mappa completa dalla splash
      _configZona = widget.preloadedData!['zone'];

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

    // 4. LOGICA DI SISTEMA (Permessi e Notifiche)
    // Usiamo Future.microtask per assicurarci che il context sia pronto per i pop-up
    Future.microtask(() async {
      if (mounted) {
        // Chiede prima il GPS
        await PositionGpsService.richiediPermessi(context);

        // Appena finito col GPS (che l'utente accetti o rifiuti), chiede le Notifiche
        if (mounted) {
          await NotificationService.richiediPermessi(context);
        }
      }
    });

    // 5. ASCOLTATORI (Listeners)
    // Reagisce quando cambi le impostazioni dei Geofence
    geofenceUpdateSignal.addListener(() async {
      if (_ultimoAggiornamento != null) {
        Map<String, dynamic> nuovaZona = await _calculateCurrentZone();
        if (mounted) setState(() => _configZona = nuovaZona);
      }
    });

    // 6. STREAM REAL-TIME (Posizione Animale)
    // Anche se abbiamo i dati della Splash, dobbiamo ascoltare i nuovi movimenti!
    _positionsRepo.subscribeToPositions();
    _streamSubscription =
        _positionsRepo.positionsStream.listen((nuovaPos) async {
      try {
        Map<String, dynamic> nuovaZona = await _calculateCurrentZone();

        if (mounted) {
          setState(() {
            _ultimoAggiornamento = nuovaPos.timestamp;
            _configZona = nuovaZona;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint('❌ [home.dart] Errore stream: $e');
      }
    });

    // 7. TIMER DI AGGIORNAMENTO UI
    // Aggiorna il testo "X min fa" ogni 30 secondi
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) setState(() {});
    });

    _inizializzaRealTimeBoard();
  }

  Future<void> _inizializzaRealTimeBoard() async {
    try {
      if (!scambio.pb.authStore.isValid) return;
      final userId = scambio.pb.authStore.model!.id;

      // 1. Troviamo il record ID interno della board associata all'utente
      final record = await scambio.pb.collection('boards').getFirstListItem(
            'user ~ "$userId"',
          );

      _currentBoardRecordId = record.id;

      // 2. Avviamo la sottoscrizione real-time
      await _usersRepo.subscribeToBoardUpdates(_currentBoardRecordId!, (data) {
        final bool nuovoStatoAllarme = data['alarm'] ?? false;

        // Se lo stato sul DB è diverso da quello locale, aggiorniamo la UI
        if (mounted && isTrackingMode.value != nuovoStatoAllarme) {
          debugPrint(
              "🔄 [home.dart] Allarme aggiornato da un altro dispositivo: $nuovoStatoAllarme");
          setState(() {
            isTrackingMode.value = nuovoStatoAllarme;
          });
        }
      });
    } catch (e) {
      debugPrint("🚨 [home.dart] Errore inizializzazione Real-time: $e");
    }
  }

  // Sottoscrizione ai cambi di stato dell'attività
  void _attivaRealTimeStatus() async {
    final boardId = await _usersRepo.getBoardIdFromBoards();
    if (boardId != null) {
      await _activitiesRepo.subscribeToActivityUpdates(boardId, (data) {
        if (mounted) {
          setState(() {
            _currentStatus = data['status'] ?? 'n';
          });
          debugPrint("📡 [home.dart] Nuovo status ricevuto: $_currentStatus");
        }
      });
    }
  }

  @override
  void dispose() {
    _activitiesRepo.unsubscribeFromActivities(); // Fondamentale disiscriversi!
    _streamSubscription?.cancel();
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  void _elaboraAttivita(List<dynamic> attivita) {
    // --- MODIFICA QUI ---
    DailyStats().elaboraListaAttivita(attivita);

    if (mounted) {
      setState(() {
        _dailyStats = DailyStats().toMap();
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
                      minimumDate: _minDataSelezionabile,
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

  // home.dart

  Future<void> _scaricaDatiAttivita(DateTime data) async {
    setState(() => _isActivityLoading = true);

    try {
      final String? boardId = await _usersRepo.getBoardIdFromBoards();

      if (boardId == null || boardId.isEmpty) {
        debugPrint(
            "⚠️ Nessuna board trovata per questo account nella collezione 'boards'.");
        if (mounted) setState(() => _isActivityLoading = false);
        return;
      }

      final attivita =
          await _activitiesRepo.fetchActivitiesByDate(boardId, data);

      // --- MODIFICA QUI: Uso l'oggetto centralizzato ---
      DailyStats().elaboraListaAttivita(attivita);

      if (mounted) {
        setState(() {
          // Aggiorno _dailyStats usando il toMap() per compatibilità con il resto della UI
          _dailyStats = DailyStats().toMap();
          _isActivityLoading = false;
        });
      }
    } catch (e) {
      debugPrint("❌ [home.dart] Errore scaricamento attività: $e");
      if (mounted) setState(() => _isActivityLoading = false);
    }
  }

  Future<void> _recuperaDataCreazioneBoard() async {
    final dataCreazione = await _usersRepo.getBoardCreationDate();
    if (dataCreazione != null && mounted) {
      setState(() {
        _minDataSelezionabile = dataCreazione;
      });
    }
  }

  Future<void> _scaricaDatiIniziali() async {
    try {
      // 1. Recupero dati Utente (per il nome nel saluto)
      final user = await _usersRepo.getCurrentUser();

      // 2. RECUPERO ID BOARD (Essenziale per lo stato attività)
      // Ci serve l'ID per sapere quale record di 'activities' monitorare
      final boardId = await _usersRepo.getBoardIdFromBoards();

      // 3. Recupero lo stato dell'allarme direttamente dalla Board
      final statoAllarme = await _usersRepo.getAlarmFromBoard();

      // 4. RECUPERO STATO OPERATIVO (Novità)
      // Controlliamo se il cane è già in modalità ricerca (s/p)
      String statusIniziale = 'n'; // Default: normale
      if (boardId != null) {
        statusIniziale = await _activitiesRepo.getLatestActivityStatus(boardId);
      }

      // 5. Recupero dati iniziali di Posizione (Timestamp e Zona)
      final tempoIniziale = await _positionsRepo.getLastTimestamp();
      final zonaIniziale = await _calculateCurrentZone();

      if (mounted) {
        setState(() {
          // Aggiorniamo il nome visualizzato
          _displayUsername = user?.username ?? 'Utente';

          // Sincronizziamo il ValueNotifier globale dell'allarme (toggle)
          isTrackingMode.value = statoAllarme;

          // AGGIORNIAMO LO STATO LOCALE (Blocca/Sblocca il toggle)
          _currentStatus = statusIniziale;

          // Aggiorniamo le informazioni geografiche
          _ultimoAggiornamento = tempoIniziale;
          _configZona = zonaIniziale;
          _isLoading = false;

          // Fermiamo il caricamento globale
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('🚨 [HOME] Errore durante il caricamento iniziale: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /* PRECEDENTE: non eliminarla, non si sa ancora se funziona la nuova
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
  } */

  // Modifica la firma e il ritorno di _calculateCurrentZone
  Future<Map<String, dynamic>> _calculateCurrentZone() async {
    try {
      final boardId = await _usersRepo.getBoardIdFromBoards();
      if (boardId == null) {
        return {
          'titolo': "Errore: Nessuna board",
          'colore': Colors.grey,
          'icona': Icons.error_outline
        };
      }

      return await _activitiesRepo.getActivityStatus(boardId);
    } catch (e) {
      debugPrint("❌ Errore in _calculateCurrentZone: $e");
      return {
        'titolo': "Errore rilevamento",
        'colore': Colors.grey,
        'icona': Icons.error_outline
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    double scale = dimensioniSchermo(context);
    double screenHeight = MediaQuery.of(context).size.height;

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
                      // Estraiamo i valori direttamente dalla nostra _configZona!
                      String displayZone =
                          _configZona['titolo'] ?? 'Sconosciuta';
                      Color zoneColor = _configZona['colore'] ?? Colors.black;
                      IconData locationIcon =
                          _configZona['icona'] ?? Icons.location_on;

                      // Mantengo la logica legacy per l'allarme hardcoded, nel caso fosse ancora necessaria
                      if (displayZone == "Fuori zona sicura") {
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
    // BLOCCO CRITICO: Se l'allarme è OFF ma lo stato è 's' (search) o 'p' (sleep search)
    // il tasto deve essere disabilitato (null nell'onChanged).
    final bool isLocked =
        !isActive && (_currentStatus == 's' || _currentStatus == 'p');

    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 15 * scale, vertical: 5 * scale),
      decoration: BoxDecoration(
          color: isLocked
              ? Colors.grey.withOpacity(0.1) // Colore spento se bloccato
              : (isActive
                  ? Colors.red.withOpacity(0.08)
                  : const Color(0xFF00C6B8).withOpacity(0.08)),
          borderRadius: BorderRadius.circular(15 * scale),
          border: Border.all(
              color: isLocked
                  ? Colors.grey.withOpacity(0.3)
                  : (isActive
                      ? Colors.red.withOpacity(0.3)
                      : const Color(0xFF00C6B8).withOpacity(0.3)))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                  isLocked
                      ? Icons.lock_clock
                      : (isActive
                          ? Icons.verified_user
                          : Icons.remove_moderator),
                  color: isLocked
                      ? Colors.grey
                      : (isActive ? Colors.red : const Color(0xFF00C6B8)),
                  size: 24 * scale),
              SizedBox(width: 10 * scale),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      isActive
                          ? "Allarme Antifuga ATTIVO"
                          : "Allarme Antifuga SPENTO",
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14 * scale,
                          color: isLocked
                              ? Colors.grey
                              : (isActive
                                  ? Colors.red
                                  : const Color(0xFF00C6B8)))),
                  if (isLocked)
                    Text("MODIFICA BLOCCATA: CANE SCAPPATO",
                        style: TextStyle(
                            fontSize: 10 * scale,
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
          Switch(
            value: isActive,
            activeColor: Colors.red,
            // Se isLocked è true, passiamo null a onChanged per disabilitare fisicamente lo Switch
            onChanged: isLocked
                ? null
                : (val) async {
                    isTrackingMode.value = val;
                    bool successo = await _usersRepo.setBoardAlarm(val);
                    if (!successo) {
                      isTrackingMode.value = !val;
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content:
                                  Text("Errore sincronizzazione allarme ⚠️")),
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
                          formattaTempoMinuti(_dailyStats['minutes']
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
          Text("Ultimo aggiornamento: ${formattaOra(ultimoInvio)}",
              style: TextStyle(
                  color: coloreStato,
                  fontWeight: FontWeight.bold,
                  fontSize: 13 * scale)),
        ],
      ),
    );
  }
}
