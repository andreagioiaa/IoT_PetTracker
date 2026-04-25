// Modifica splash_view.dart
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

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        duration: const Duration(milliseconds: 1500), vsync: this);
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _controller.forward();

    _loadAppAndNavigate();
  }

  Future<void> _loadAppAndNavigate() async {
    final startTime = DateTime.now();

    // 1. Controllo immediato dell'autenticazione
    if (!widget.isAlreadyAuthenticated) {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (context) => const AuthScreen()));
      }
      return;
    }

    try {
      // Inizializzazione Repository
      final usersRepo = UsersRepository();
      final positionsRepo = PositionsRepository(scambio.pb);
      final activitiesRepo = ActivitiesRepository(scambio.pb);
      final geofenceRepo = GeofenceRepository(scambio.pb);

      // --- FASE 1: RECUPERO IDENTITÀ E BOARD ---
      // Queste operazioni devono essere fatte prima delle altre perché il boardId è vitale
      final user = await usersRepo.getCurrentUser();

      // Cerchiamo la board collegata all'utente nella collezione "boards"
      final String? boardId = await usersRepo.getBoardIdFromBoards();

      if (boardId == null || boardId.isEmpty) {
        debugPrint("⚠️ Errore: Nessuna board associata all'utente loggato.");
        throw Exception("Board non trovata");
      } else {
        debugPrint("✅ Board trovata: " + boardId + "!");
      }

      // --- FASE 2: CARICAMENTO DATI IN PARALLELO ---
      // Ora che abbiamo il boardId, carichiamo tutto il resto contemporaneamente per massimizzare la velocità ⚡
      final results = await Future.wait([
        usersRepo.getAlarmStatus(), // [0]
        positionsRepo.getLatestPosition(), // [1]
        activitiesRepo.fetchActivitiesByDate(
            boardId, DateTime.now()), // [2] <- DINAMICO!
      ]);

      // Estrazione e Casting dei risultati
      final bool? alarm = results[0] as bool?;
      final pos = results[1] as Positions?;
      final activities = results[2];

      // --- FASE 3: ELABORAZIONE FINALE (GEOFENCING) ---
      String zona = "Posizione sconosciuta";
      if (pos != null) {
        // Calcolo della zona basato sulle coordinate dinamiche
        zona = await geofenceRepo.getZoneForPoint(LatLng(pos.lat, pos.lon));
      }

      // Gestione del tempo minimo di visualizzazione della Splash (2.5 secondi)
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed < const Duration(milliseconds: 2500)) {
        await Future.delayed(const Duration(milliseconds: 2500) - elapsed);
      }

      // --- FASE 4: NAVIGAZIONE ALLA HOME ---
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PetTrackerNavigation(
              preloadedData: {
                'username': user?.username ?? 'User',
                'alarm': alarm ?? false,
                'lastPosition': pos,
                'activities': activities,
                'zone': zona,
                'boardId':
                    boardId, // Passiamo il boardId per usi futuri nella Home
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("🛑 Errore critico nel caricamento Splash: $e");
      // In caso di errore, riportiamo l'utente a una navigazione sicura o al login
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
