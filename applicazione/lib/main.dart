import 'package:flutter/material.dart';
import 'login.dart'; // Importi il tuo file login

void main() {
  runApp(const PetTrackerApp());
}

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pet Tracker',
      // Qui imposti la classe che hai definito in login.dart
      home: const AuthScreen(), 
    );
  }
}