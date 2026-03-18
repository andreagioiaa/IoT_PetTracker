// In main.dart
import 'package:flutter/foundation.dart'; // NECESSARIO per kDebugMode
import 'package:flutter/material.dart';
import 'splash_screen.dart';
// Importa la tua Home o la pagina che vuoi vedere in debug
import 'home.dart';

void main() => runApp(const PetTrackerApp());

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pet Tracker',
      theme: ThemeData(primarySwatch: Colors.teal),
      home: kDebugMode ? const PetTrackerNavigation() : const SplashScreen(),
    );
  }
}
