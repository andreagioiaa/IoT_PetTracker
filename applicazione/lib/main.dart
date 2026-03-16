import 'package:flutter/material.dart';
import 'battery.dart';
import 'geofencing.dart';
import 'dart:math';

void main() {
  runApp(const PetTrackerApp());
}

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pet Tracker LoRaWAN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        primarySwatch: Colors.teal,
      ),
      home: const PetTrackerNavigation(),
    );
  }
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

  @override
  void initState() {
    super.initState();
    _initializeDates();
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

                // Card Posizione Attuale
                _buildPositionCard(),

                const SizedBox(height: 25),

                // Calendario Orizzontale
                _buildMonthHeader(),
                const SizedBox(height: 10),
                _buildHorizontalCalendar(),

                const SizedBox(height: 30),

                // Attività Odierna con Cerchi Statistici
                const Text("Attività Odierna",
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                _buildActivityStats(),

                const SizedBox(height: 30),

                // Info LoRaWAN
                _buildLoraInfoPanel(),
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
          navState.setState(() {
            navState._currentIndex = 1;
          });
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
              // Aggiunto per gestire bene lo spazio
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text("Posizione Attuale",
                      style: TextStyle(color: Colors.black45)),
                  Text("In Recinto (Casa)",
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
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
        Text(
          currentMonthName,
          style: const TextStyle(
              fontSize: 18, color: Colors.black54, fontWeight: FontWeight.w500),
        ),
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
                duration: const Duration(milliseconds: 0),
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
                    Text(
                      dates[index]['day']!,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF2D3142)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      dates[index]['weekDay']!,
                      style: TextStyle(
                          fontSize: 10,
                          color: isSelected ? Colors.white70 : Colors.black45),
                    ),
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
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
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

  Widget _buildLoraInfoPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF00C6B8).withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF00C6B8).withOpacity(0.3)),
      ),
      child: const Text(
        "Ultimo aggiornamento ricevuto: 2 minuti fa",
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFF007A71), fontWeight: FontWeight.w500),
      ),
    );
  }
}
