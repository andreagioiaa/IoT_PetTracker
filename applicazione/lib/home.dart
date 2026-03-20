import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'scambio.dart' as scambio;

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({Key? key}) : super(key: key);

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
  if (ultimoInvio == null) return "Dato non disponibile";

  final oraAttuale = DateTime.now();
  final differenza = oraAttuale.difference(ultimoInvio);

  // --- OUTPUT RICHIESTO PER IL DEBUG ---
  print("-----------------------------------------");
  print("🕒 ANALISI TEMPORALE:");
  print("📍 Ultimo Invio (Locale): $ultimoInvio");
  print("📱 Ora Attuale (Locale):   $oraAttuale");
  print("⏳ Differenza (Secondi):  ${differenza.inSeconds}");
  print("-----------------------------------------");

  if (differenza.isNegative) {
    // Se la differenza è negativa, forziamo "Adesso" per la UI
    // ma manteniamo il log per capire l'errore
    return "In tempo reale (${differenza.inSeconds}s)";
  }

  if (differenza.inSeconds < 60) {
    return "Adesso";
  } else if (differenza.inMinutes < 60) {
    return "${differenza.inMinutes} min fa";
  } else {
    return "${differenza.inHours} ore fa";
  }
}

// Funzione helper per il colore dello stato
Color getColoreStato(DateTime? ultimoInvio) {
  if (ultimoInvio == null) return Colors.grey;
  final differenza = DateTime.now().difference(ultimoInvio);

  if (differenza.inMinutes < 30) return const Color(0xFF00C6B8); // Tutto ok
  if (differenza.inMinutes < 60) return Colors.orange; // Ritardo lieve
  return Colors.red; // Ritardo critico
}

class PetTrackerNavigation extends StatefulWidget {
  const PetTrackerNavigation({Key? key}) : super(key: key);

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
  const PetTrackerDashboard({Key? key}) : super(key: key);

  @override
  State<PetTrackerDashboard> createState() => _PetTrackerDashboardState();
}

class _PetTrackerDashboardState extends State<PetTrackerDashboard> {
  late List<Map<String, String>> dates;
  late int selectedDateIndex;
  late String currentMonthName;

  // Future per i dati dinamici
  late Future<DateTime?> _lastUpdateFuture;
  late Future<String> _currentZoneFuture; // <-- Nuovo Future per il recinto

  @override
  void initState() {
    super.initState();
    _initializeDates();
    _lastUpdateFuture = scambio.getUltimoTimestamp();
    _currentZoneFuture = _calculateCurrentZone(); // <-- Avviamo il calcolo
  }

  void _initializeDates() {
    DateTime today = DateTime.now();
    List<String> monthNames = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    currentMonthName = monthNames[today.month - 1];
    List<String> weekDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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

  // --- MAGIA IoT: CALCOLO SE IL CANE È NEL RECINTO ---
  Future<String> _calculateCurrentZone() async {
    if (!scambio.isReady) await scambio.autenticazione();

    try {
      // 1. Prendiamo l'ultima posizione registrata del cane
      final posResult = await scambio.pb.collection('positions_test').getList(
            page: 1,
            perPage: 1,
            sort: '-timestamp', // Prendi il più recente
          );

      if (posResult.items.isEmpty) return "Posizione sconosciuta";

      final petLat = posResult.items.first.getDoubleValue('lat');
      final petLon = posResult.items.first.getDoubleValue('lon');
      final petLocation = LatLng(petLat, petLon);

      // 2. Prendiamo tutte le zone sicure (geofences)
      final geoResult =
          await scambio.pb.collection('geofences_test').getFullList();

      // 3. Calcoliamo la distanza
      const distanceTool = Distance(); // Strumento di latlong2

      for (var record in geoResult) {
        final zLat = record.getDoubleValue('center_lat');
        final zLon = record.getDoubleValue('center_lon');
        final radius = record.getDoubleValue('radius');
        final nomeZona = record.getStringValue('name');

        // Calcola distanza in metri tra il cane e il centro della zona
        final distMeters =
            distanceTool.as(LengthUnit.Meter, petLocation, LatLng(zLat, zLon));

        // Se il cane è dentro al raggio, restituisci solo il NOME
        if (distMeters <= radius) {
          return nomeZona;
        }
      }

      // Se finisce il ciclo e non è in nessuna zona
      return "Fuori zona sicura";
    } catch (e) {
      debugPrint("Errore calcolo zona: $e");
      return "Errore rilevamento";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          right: 0,
          child: Container(
            width: 200,
            height: 150,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                  colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)]),
              borderRadius: BorderRadius.only(bottomLeft: Radius.circular(100)),
            ),
          ),
        ),
        SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                const Text('Bentornato,',
                    style: TextStyle(fontSize: 16, color: Colors.black54)),
                const Text('Alberto Angela',
                    style:
                        TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 25),

                _buildPositionCard(), // <-- Card aggiornata

                const SizedBox(height: 25),
                _buildMonthHeader(),
                const SizedBox(height: 10),
                _buildHorizontalCalendar(),

                const SizedBox(height: 30),
                const Text("Attività Odierna",
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                _buildActivityStats(),

                const SizedBox(height: 30),

                // Pannello dinamico con FutureBuilder
                FutureBuilder<DateTime?>(
                  future: _lastUpdateFuture,
                  builder: (context, snapshot) {
                    return _buildLoraInfoPanel(snapshot.data);
                  },
                ),

                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPositionCard() {
    return GestureDetector(
      onTap: () {
        final navState =
            context.findAncestorStateOfType<_PetTrackerNavigationState>();
        if (navState != null) {
          navState.setState(() => navState._currentIndex = 1);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 15)
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.location_on, color: Color(0xFF00C6B8), size: 40),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Posizione Attuale",
                      style: TextStyle(color: Colors.black45)),

                  // Inseriamo un FutureBuilder che attende il nome del recinto!
                  FutureBuilder<String>(
                      future: _currentZoneFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Text("Ricerca in corso...",
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: Colors.grey));
                        }

                        final nomeRecinto = snapshot.data ?? "Sconosciuta";

                        return Text(nomeRecinto,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                                // Se è fuori zona, metto il testo in rosso per allertare!
                                color: nomeRecinto == "Fuori zona sicura"
                                    ? Colors.red
                                    : Colors.black));
                      }),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios,
                color: Colors.black12, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthHeader() {
    return Row(
      children: [
        const Icon(Icons.calendar_month, color: Color(0xFF00C6B8), size: 20),
        const SizedBox(width: 8),
        Text(currentMonthName,
            style: const TextStyle(
                fontSize: 18,
                color: Colors.black54,
                fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildHorizontalCalendar() {
    return SizedBox(
      width: double.infinity,
      height: 90,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(dates.length, (index) {
          bool isSelected = index == selectedDateIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedDateIndex = index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  gradient: isSelected
                      ? const LinearGradient(
                          colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)])
                      : null,
                  color: isSelected ? null : Colors.white,
                  borderRadius: BorderRadius.circular(15),
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
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF2D3142))),
                    const SizedBox(height: 4),
                    Text(dates[index]['weekDay']!,
                        style: TextStyle(
                            fontSize: 10,
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

  Widget _buildActivityStats() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildStatCircle("Passi", "1.240", Icons.pets, Colors.orange),
        _buildStatCircle("Km", "2.4", Icons.straighten, Colors.blue),
        _buildStatCircle("Minuti", "45", Icons.timer, Colors.purple),
      ],
    );
  }

  Widget _buildStatCircle(
      String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Container(
          width: 65,
          height: 65,
          decoration: BoxDecoration(
              color: color.withOpacity(0.1), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 25),
        ),
        const SizedBox(height: 10),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        Text(label,
            style: const TextStyle(color: Colors.black38, fontSize: 13)),
      ],
    );
  }

  // PANNELLO DINAMICO AGGIORNATO
  Widget _buildLoraInfoPanel(DateTime? ultimoInvio) {
    final coloreStato = getColoreStato(ultimoInvio);
    final testoTempo = formattaUltimoAggiornamento(ultimoInvio);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: coloreStato.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: coloreStato.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sync, color: coloreStato, size: 18),
          const SizedBox(width: 10),
          Text(
            "Ultimo aggiornamento: $testoTempo",
            style: TextStyle(
                color: coloreStato.withOpacity(0.8),
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
