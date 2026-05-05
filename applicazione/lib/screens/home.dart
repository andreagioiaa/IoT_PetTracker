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
import "../utils/helpers.dart";
import '../models/statistics.dart';

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

// Funzione per determinare il colore dello stato in base all'ultimo aggiornamento della posizione
Color getColoreStato(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return Colors.grey;

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

    // Imposta il valore dell'allarme PRIMA di costruire la UI
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
  final ActivitiesRepository _activitiesRepo = ActivitiesRepository(scambio.pb);

  // Inizializzia l'oggetto con valori a zero tramite costruttore
  DailyStats _statisticheOggi = DailyStats.empty();

  // Variabili per la gestione della riga dei giorni
  late List<Map<String, String>> dates;
  late int selectedDateIndex;
  late String currentMonthName;
  DateTime? _ultimoAggiornamento;

  // Config dinamica per titolo, colore e icona della zona (aggiornata in tempo reale)
  Map<String, dynamic> _configZona = {
    'titolo': 'Ricerca in corso...',
    'colore': Colors.grey,
    'icona': Icons.location_on
  };

  // Variabile per il nome visualizzato (caricamento iniziale...)
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

  // Variabile per fare da "Mutex" (Lock) durante la chiamata di rete
  bool _isUpdatingAlarm = false;
  // Nuova variabile per tenere traccia dello stato operativo (s, p, n)
  String _currentStatus = 'n';

  @override
  void initState() {
    super.initState();
    _initializeDates();
    _recuperaDataCreazioneBoard();

    // Caricamento dati e attivazione ascoltatori
    _scaricaDatiIniziali();
    _attivaRealTimeStatus();

    // 3. INIEZIONE DATI PRE-CARICATI (Dalla Splash)
    // Questo elimina il testo "Caricamento..." istantaneamente se i dati ci sono
    if (widget.preloadedData != null) {
      _displayUsername = widget.preloadedData!['username'];

      // Estraiamo la mappa completa dalla splash
      _configZona = widget.preloadedData!['zone'];

      final pos = widget.preloadedData!['lastPosition'];
      if (pos != null) _ultimoAggiornamento = pos.timestamp;

      // Se lo Splash ci ha passato le statistiche complete (con i KM calcolati)
      if (widget.preloadedData!['daily_stats'] != null) {
        _statisticheOggi = widget.preloadedData!['daily_stats'];
      }
      // Altrimenti usiamo il vecchio metodo di fallback
      else if (widget.preloadedData!['activities'] != null) {
        _elaboraAttivita(widget.preloadedData!['activities']);
      }

      // E infine, se la Splash ci ha passato anche lo stato operativo, usiamolo per aggiornare subito la UI
      if (widget.preloadedData!['status'] != null) {
        _currentStatus = widget.preloadedData![
            'status']; // Ora sa se il cane è scappato fin dall'apertura!
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
          if (DateUtils.isSameDay(_dataSelezionata, DateTime.now())) {
            _scaricaDatiAttivita(_dataSelezionata);
          }
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
          // 1. Aggiorna SUBITO lo stato locale (così non si blocca il lucchetto)
          setState(() {
            _currentStatus = data['status'] ?? 'n';
          });
          debugPrint("📡 [home.dart] Nuovo status ricevuto: $_currentStatus");

          // 2. Chiama la funzione per aggiornare titoli, colori e icone (in background)
          _aggiornaGraficaZonaDaFunzioni();
        }
      });
    }
  }

  // Utilizza la logica di aggiornamento grafico basata sullo stato dell'attività
  Future<void> _aggiornaGraficaZonaDaFunzioni() async {
    try {
      // Usa la TUA funzione che passa per getActivityStatus e _getNomeZonaDaPosizione
      Map<String, dynamic> nuovaZona = await _calculateCurrentZone();

      if (mounted) {
        setState(() {
          _configZona = nuovaZona; // Applica la grafica aggiornata
        });
      }
    } catch (e) {
      debugPrint("❌ Errore aggiornamento grafica zona: $e");
    }
  }

  @override
  void dispose() {
    _activitiesRepo.unsubscribeFromActivities();
    _streamSubscription?.cancel();
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  void _elaboraAttivita(List<dynamic> attivita) {
    if (mounted) {
      setState(() {
        // Zero calcoli nella UI: passiamo la palla direttamente alla repository!
        _statisticheOggi = ActivitiesRepository.parsePreloadedData(attivita);
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

  // Nuova funzione per scaricare i dati di attività filtrati per giorno e aggiornare le statistiche
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
      // Passa la data selezionata al repository per ottenere solo le attività di quel giorno
      final statsCalcolate =
          await _activitiesRepo.getDailyStatistics(boardId, data);

      if (mounted) {
        setState(() {
          _statisticheOggi = statsCalcolate;
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
    // BLOCCO CRITICO: Se l'allarme è ON ma lo stato è 's' (search) o 'p' (sleep search) significa che il cane è scappato
    // quindi blocchiamo la possibilità di spegnere l'allarme finché non tornerà in zona sicura (stato 'n')
    final bool isLocked =
        isActive && (_currentStatus == 's' || _currentStatus == 'p');

    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 15 * scale, vertical: 5 * scale),
      decoration: BoxDecoration(
          color: isLocked
              ? Colors.red.withOpacity(0.08) // Mantiene il rossino di emergenza
              : (isActive
                  ? Colors.red.withOpacity(0.08)
                  : const Color(0xFF00C6B8).withOpacity(0.08)),
          borderRadius: BorderRadius.circular(15 * scale),
          border: Border.all(
              color: isLocked
                  ? Colors.red.withOpacity(0.4) // Bordo rosso ben visibile
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
                      ? Icons.lock // Messo il lucchetto come nella tua foto
                      : (isActive
                          ? Icons.verified_user
                          : Icons.remove_moderator),
                  color: isActive
                      ? Colors.red
                      : const Color(0xFF00C6B8), // Resta rosso!
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
                          color:
                              isActive ? Colors.red : const Color(0xFF00C6B8))),
                  if (isLocked)
                    Text("MODIFICA BLOCCATA",
                        style: TextStyle(
                            fontSize: 10 * scale,
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
          // Se si aggiona mostra un indicatore di caricamento al posto dello Switch
          _isUpdatingAlarm
              ? Padding(
                  padding: EdgeInsets.only(right: 10 * scale),
                  child: SizedBox(
                      width: 20 * scale,
                      height: 20 * scale,
                      child: CircularProgressIndicator(
                          color: Colors.red, strokeWidth: 2)),
                )
              : Switch(
                  value: isActive,
                  activeColor: Colors.red,
                  onChanged: isLocked
                      ? (val) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  "Impossibile disattivare: l'animale è fuori dalla zona sicura! 🚨"),
                              backgroundColor: Colors.red,
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      : (val) async {
                          // 1. Aacquisice IL LOCK (Mutex)
                          setState(() {
                            _isUpdatingAlarm = true;
                          });

                          // 2. Aggiorniamo immediatamente la UI per una risposta istantanea
                          isTrackingMode.value = val;

                          // 3. Sezione critica: aggiorniamo il database e aspettiamo la conferma
                          bool successo = await _usersRepo.setBoardAlarm(val);

                          // 4. Se la sincronizzazione fallisce, cambia la UI e mostra un messaggio di errore
                          if (!successo) {
                            isTrackingMode.value = !val;
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        "Errore sincronizzazione allarme ⚠️")),
                              );
                            }
                          }

                          // 5. Rilascia il lock
                          if (mounted) {
                            setState(() {
                              _isUpdatingAlarm = false;
                            });
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
                  onTap: (_isActivityLoading ||
                          _dataSelezionata.isBefore(_minDataSelezionabile) ||
                          DateUtils.isSameDay(
                              _dataSelezionata, _minDataSelezionabile))
                      ? null
                      : () {
                          // Calcoliamo il giorno precedente
                          DateTime nuovaData = _dataSelezionata
                              .subtract(const Duration(days: 1));

                          // Controllo extra per sicurezza
                          if (nuovaData.isBefore(_minDataSelezionabile) &&
                              !DateUtils.isSameDay(
                                  nuovaData, _minDataSelezionabile)) return;

                          setState(() {
                            _dataSelezionata = nuovaData;
                          });
                          _scaricaDatiAttivita(_dataSelezionata);
                        },
                  child: Padding(
                    padding: EdgeInsets.all(8.0 * scale),
                    child: Icon(Icons.chevron_left,
                        color: (_isActivityLoading ||
                                _dataSelezionata
                                    .isBefore(_minDataSelezionabile) ||
                                DateUtils.isSameDay(
                                    _dataSelezionata, _minDataSelezionabile))
                            ? Colors.black12
                            : Colors.black54,
                        size: 28 * scale),
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
                  onTap: (_isActivityLoading ||
                          DateUtils.isSameDay(
                              _dataSelezionata, DateTime.now()) ||
                          _dataSelezionata.isAfter(DateTime.now()))
                      ? null
                      : () {
                          // Calcoliamo il giorno successivo
                          DateTime nuovaData =
                              _dataSelezionata.add(const Duration(days: 1));

                          // Controllo extra per evitare giorni futuri
                          if (nuovaData.isAfter(DateTime.now()) &&
                              !DateUtils.isSameDay(nuovaData, DateTime.now()))
                            return;

                          setState(() {
                            _dataSelezionata = nuovaData;
                          });
                          _scaricaDatiAttivita(_dataSelezionata);
                        },
                  child: Padding(
                    padding: EdgeInsets.all(8.0 * scale),
                    child: Icon(Icons.chevron_right,
                        color: (_isActivityLoading ||
                                DateUtils.isSameDay(
                                    _dataSelezionata, DateTime.now()) ||
                                _dataSelezionata.isAfter(DateTime.now()))
                            ? Colors.black12
                            : Colors.black54,
                        size: 28 * scale),
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
                      _buildCompactStat("Passi", "${_statisticheOggi.steps}",
                          Icons.pets, Colors.orange, scale),
                      _buildCompactStat("Km", _statisticheOggi.formattedKm,
                          Icons.straighten, Colors.blue, scale),
                      _buildCompactStat(
                          "Durata",
                          formattaTempoMinuti(_statisticheOggi.minutes),
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
                Icons.format_list_bulleted_rounded,
                size: 20 * scale,
                color: const Color(0xFF009B90),
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
