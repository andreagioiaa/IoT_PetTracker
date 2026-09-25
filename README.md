# IoT Pet Tracker

Sistema per il tracciamento in tempo reale di animali domestici, sviluppato per il corso di
Internet of Things del corso di laurea in IBML (Internet of Things, Big Data, Machine Learning) 
dell'Università degli Studi di Udine.

Il sistema è composto da un dispositivo embedded indossabile (ESP32-S3 + LTE + GNSS),
un backend basato su PocketBase, un'app mobile Flutter e un microservizio Node.js per
l'invio delle notifiche push tramite Firebase Cloud Messaging.

## Struttura del repository

```
IoT_PetTracker/
├── application/            # App mobile (Flutter)
├── node-server/            # Bridge per le notifiche push (Node.js)
├── pb_hooks/               # Logica server-side del backend (PocketBase / JavaScript)
├── report/                 # Relazione del progetto (LaTeX)
└── tracker_sim7670g_s3/    # Firmware del dispositivo (Arduino/ESP32-S3)
```

### `application/` — App mobile Flutter

App multipiattaforma per la visualizzazione della posizione, delle attività dell'animale
e la gestione delle zone di sicurezza (geofencing).

- `lib/` — codice sorgente dell'app (entry point: `main.dart`)
- `android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/` — configurazioni e progetti
  nativi generati da Flutter per ciascuna piattaforma (build system, manifest, ecc.)
- `assets/` — risorse statiche dell'app (immagini, icone, ecc.)
- `test/` — test automatici
- `src py/` — script Python di supporto allo sviluppo, non parte dell'app:
  - `crea_datiTest.py` — genera dati di test per il backend
  - `[NO USE] pocketbase_population.py` — script non più utilizzato, da rimuovere o
    tenere solo per riferimento
- `.env` — variabili d'ambiente (URL del backend, chiavi, ecc.) — **non incluso nella repository**
- `pubspec.yaml` / `pubspec.lock` — dipendenze del progetto Flutter
- `build/`, `.dart_tool/` — output di build, generati automaticamente, non incluso nella repository

Per avviare l'app in locale:
```bash
cd application
flutter pub get
flutter run
```

### `node-server/` — FCM Bridge

Microservizio Node.js che riceve richieste HTTP dal backend PocketBase e inoltra le
notifiche push tramite l'SDK ufficiale Firebase Admin. Necessario perché il runtime
JavaScript di PocketBase (Goja) non supporta i moduli nativi richiesti dall'SDK Firebase.

- `index.js` — entry point del servizio

Per avviarlo:
```bash
cd node-server
npm install
node index.js
```

### `pb_hooks/` — Backend (PocketBase, server-side hooks)

Logica applicativa eseguita lato server da PocketBase: elaborazione dei pacchetti
ricevuti dal dispositivo, macchina a stati delle attività, cron job (watchdog, split
notturno).

- `main.pb.js` — entry point, registra gli hook sugli eventi e i cron job
- `activity_manager.js` — macchina a stati che classifica l'attività dell'animale
- `constants.js` — costanti condivise (timeout, soglie, ecc.)
- `utils.js` — funzioni di utilità

Questi file vanno copiati nella cartella `pb_hooks/` dell'installazione di PocketBase
per essere caricati automaticamente all'avvio del server.

### `report/` — Relazione (LaTeX)

Sorgente della relazione del progetto.

- `report.tex` — sorgente principale
- `bibliography.bib` — riferimenti bibliografici
- `immages/` — immagini incluse nella relazione
- `report.pdf` — output compilato

Gli altri file (`.aux`, `.bbl`, `.log`, ecc.) sono file temporanei generati da LaTeX e
sono esclusi dalla repo (vedi `.gitignore`).

### `tracker_sim7670g_s3/` — Firmware del dispositivo

Firmware Arduino per la scheda LilyGo T-SIM7670G-S3 (ESP32-S3 + modem LTE/GNSS
SIM7670G + accelerometro BMA400). Gestisce l'acquisizione GPS, il risparmio energetico
(deep sleep / hot start) e la trasmissione dei dati al backend via HTTPS.

- `tracker_sim7670g_s3.ino` — sorgente del firmware

Da compilare e caricare tramite Arduino IDE (o PlatformIO) con il supporto per le
board ESP32-S3 installato.

## Requisiti generali

- Flutter SDK (per `application/`)
- Node.js (per `node-server/`)
- Un'istanza PocketBase in esecuzione, con i file di `pb_hooks/` copiati nella cartella
  corrispondente
- Arduino IDE / PlatformIO con supporto ESP32-S3 (per il firmware)
- Distribuzione LaTeX (es. TeX Live) con `latexmk` (per compilare la relazione)

## Note

- `src py/pocketbase_population.py` è marcato come non più utilizzato, dato che è stato utilizzato solo in fase di test.
