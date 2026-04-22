import 'package:flutter/material.dart';
import 'dart:async';
import 'login.dart';
import 'home.dart';

class SplashScreen extends StatefulWidget {
  // Aggiungiamo questa variabile
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
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );

    _controller.forward();

    // 🕒 LOGICA DI NAVIGAZIONE INTELLIGENTE
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        // Se l'utente è autenticato va alla Home, altrimenti al Login
        Widget destination = widget.isAlreadyAuthenticated
            ? const PetTrackerNavigation()
            : const AuthScreen();

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => destination),
        );
      }
    });
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
              Icon(
                Icons.pets,
                size: 80,
                color: Colors.teal,
              ),
              SizedBox(height: 20),
              Text(
                'Pet Tracker',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.teal,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
