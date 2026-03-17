// In main.dart
import 'package:flutter/material.dart';
import 'splash_screen.dart'; // Importa il nuovo file

void main() => runApp(const PetTrackerApp());

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pet Tracker',
      theme: ThemeData(primarySwatch: Colors.blue),
      // PUNTO FONDAMENTALE: L'app ora parte dallo Splash
      home: const SplashScreen(), 
    );
  }
}