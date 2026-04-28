import 'package:flutter/material.dart';
import 'dart:async';
import 'package:latlong2/latlong.dart';
import 'login.dart';
import 'home.dart';
import '../models/positions.dart';
import '../repositories/users_repo.dart';
import '../repositories/positions_repo.dart';
import '../repositories/activities_repo.dart';
import '../repositories/geofences_repo.dart';
import '../services/authentication.dart' as scambio;

class SplashScreen extends StatefulWidget {
  final bool isAlreadyAuthenticated;
  const SplashScreen({super.key, required this.isAlreadyAuthenticated});

  // --- FUNZIONE STATICA GLOBALE ---
  // Raccoglie i dati in parallelo. Essendo "static", la pagina di Login
  // può chiamare questa funzione senza mostrare la grafica della zampa!
  static Future<Map<String, dynamic>> preparaDatiPerHome() async {
    final usersRepo = UsersRepository();
    final positionsRepo = PositionsRepository(scambio.pb);
    final activitiesRepo = ActivitiesRepository(scambio.pb);
    final geofenceRepo = GeofenceRepository(scambio.pb);

    try {
      final user = await usersRepo.getCurrentUser();
      final String? boardId = await usersRepo.getBoardIdFromBoards();

      if (boardId == null || boardId.isEmpty) {
        throw Exception("Nessuna board trovata per questo utente");
      }

      // Eseguiamo il download in parallelo per dimezzare i tempi di caricamento
      final results = await Future.wait([
        usersRepo.getAlarmStatus(),
        positionsRepo.getLatestPosition(),
        activitiesRepo.fetchActivitiesByDate(boardId, DateTime.now()),
      ]);

      final bool? alarm = results[0] as bool?;
      final pos = results[1] as Positions?;
      final activities = results[2];

      String zona = "Posizione sconosciuta";
      if (pos != null) {
        zona = await geofenceRepo.getZoneForPoint(LatLng(pos.lat, pos.lon));
      }

      return {
        'username': user?.username ?? 'Utente',
        'alarm': alarm ?? false,
        'lastPosition': pos,
        'activities': activities,
        'zone': zona,
        'boardId': boardId,
      };
    } catch (e) {
      debugPrint('🚨 Errore in preparaDatiPerHome: $e');
      // Dati di fallback sicuri in caso di assenza di rete o errori
      return {
        'username': 'Utente',
        'alarm': false,
        'lastPosition': null,
        'activities': [],
        'zone': "Errore connessione",
        'boardId': null,
      };
    }
  }

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  // Definiamo il tempo minimo in cui la zampa deve rimanere a schermo (in millisecondi)
  final int _tempoMinimoSplash = 2500;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        duration: const Duration(milliseconds: 1500), vsync: this);
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _controller.forward();

    _loadAppAndNavigate();
  }

  Future<void> _attendiTempoRimanente(Stopwatch stopwatch) async {
    int trascorso = stopwatch.elapsedMilliseconds;
    if (trascorso < _tempoMinimoSplash) {
      await Future.delayed(
          Duration(milliseconds: _tempoMinimoSplash - trascorso));
    }
  }

  Future<void> _loadAppAndNavigate() async {
    Stopwatch stopwatch = Stopwatch()..start();

    // SCENARIO A: Utente NON autenticato
    if (!widget.isAlreadyAuthenticated) {
      await _attendiTempoRimanente(stopwatch);
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (context) => const AuthScreen()));
      }
      return;
    }

    // SCENARIO B: Utente Autenticato -> Scarichiamo i dati
    try {
      // Usiamo la nostra nuova funzione!
      final datiHome = await SplashScreen.preparaDatiPerHome();

      await _attendiTempoRimanente(stopwatch);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PetTrackerNavigation(preloadedData: datiHome),
          ),
        );
      }
    } catch (e) {
      debugPrint("🛑 Errore critico nel caricamento Splash: $e");
      await _attendiTempoRimanente(stopwatch);
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (context) => const AuthScreen()));
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: ScaleTransition(
          scale: _animation,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.pets, size: 80, color: Colors.teal),
              SizedBox(height: 20),
              Text('Pet Tracker',
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal)),
            ],
          ),
        ),
      ),
    );
  }
}
