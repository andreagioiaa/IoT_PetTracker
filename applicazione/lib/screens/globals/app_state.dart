import 'package:flutter/material.dart';

// --- VARIABILI GLOBALI DI STATO DELL'APP ---

// Modalità allarme/inseguimento
final ValueNotifier<bool> isTrackingMode = ValueNotifier(false);

// Segnale per forzare l'aggiornamento della mappa (es. dopo aver salvato un'area)
final ValueNotifier<int> geofenceUpdateSignal = ValueNotifier(0);

// Preferenza di focus sulla mappa ('Animale' o 'Dispositivo')
final ValueNotifier<String> mapFocusPreference = ValueNotifier('Animale');

// Stato dei permessi GPS
final ValueNotifier<bool> hasLocationPermission = ValueNotifier(false);

// Stato dei permessi di notifica
final ValueNotifier<bool> hasNotificationPermission = ValueNotifier(false);
