#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>
#include <Preferences.h>
#include <TinyGPS++.h>
#include <HardwareSerial.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>

// ===================== PIN LORA SX1262 =====================
#define LORA_NSS  8
#define LORA_SCK  9
#define LORA_MOSI 10
#define LORA_MISO 11
#define LORA_DIO1 14
#define LORA_NRST 12
#define LORA_BUSY 13

// ===================== PIN GPS UC6580 =====================
#define RX_PIN    33
#define TX_PIN    34
#define GPS_RST_PIN 35   // Active-LOW reset: tieni HIGH per far funzionare il GPS
#define GPS_BAUD  115200

// ===================== PIN TFT ST7735S =====================
#define TFT_CS   38
#define TFT_RST  39
#define TFT_DC   40
#define TFT_SCLK 41
#define TFT_MOSI 42
#define TFT_LED  21

// ===================== PIN ALTRI =====================
#define VEXT_PIN     3
#define VBAT_PIN     1
#define ADC_CTRL_PIN 2

// ===================== PARAMETRI =====================
#define GPS_TIMEOUT_MS      120000
#define uS_TO_S_FACTOR      1000000ULL
#define SLEEP_TIME          30
#define MIN_DISTANCE_METERS 5.0

// ===================== COLORI TFT =====================
#define COLOR_BG      ST77XX_BLACK
#define COLOR_TITLE   0x07FF   // Ciano
#define COLOR_OK      ST77XX_GREEN
#define COLOR_WARN    ST77XX_YELLOW
#define COLOR_ERR     ST77XX_RED
#define COLOR_WHITE   ST77XX_WHITE
#define COLOR_GRAY    0x8410
#define COLOR_ORANGE  0xFD20

// ===================== OGGETTI =====================
// Display: usa il bus SPI dedicato (VSPI/FSPI su ESP32-S3 = SPI3, pin 41/42)
SPIClass tftSpi(FSPI);
Adafruit_ST7735 tft = Adafruit_ST7735(&tftSpi, TFT_CS, TFT_DC, TFT_RST);

// Radio
SPIClass hspi(HSPI);
SPISettings spiSettings(2000000, MSBFIRST, SPI_MODE0);
SX1262 radio = new Module(LORA_NSS, LORA_DIO1, LORA_NRST, LORA_BUSY, hspi, spiSettings);
LoRaWANNode node(&radio, &EU868);
Preferences preferences;

// Gps
HardwareSerial gpsSerial(1);
TinyGPSPlus gps;

// ===================== CREDENZIALI LORAWAN =====================
uint64_t joinEUI = 0x0000000000000000;
uint64_t devEUI  = 0x70B3D57ED007645D;
uint8_t appKey[] = { 0x4B, 0xD9, 0x00, 0x7E, 0x00, 0x83, 0x03, 0x53,
                     0xAF, 0x58, 0x4E, 0xCE, 0xC6, 0xAA, 0x45, 0x90 };

// ===================== RTC RAM (persiste nel deep sleep) =====================
RTC_DATA_ATTR bool     isJoined    = false;
RTC_DATA_ATTR uint8_t  lw_session[RADIOLIB_LORAWAN_SESSION_BUF_SIZE];
RTC_DATA_ATTR uint8_t  lw_nonces[RADIOLIB_LORAWAN_NONCES_BUF_SIZE];
RTC_DATA_ATTR uint16_t bootCount   = 0;
RTC_DATA_ATTR double   last_lat    = 0.0;
RTC_DATA_ATTR double   last_lng    = 0.0;
RTC_DATA_ATTR bool     has_last_fix = false;

// ===================== PROTOTIPI =====================
void goToDeepSleep(uint64_t sleepSeconds);
bool getGpsFix();
float readBattery();
void initDisplay();
void displayHeader(uint16_t bootNum);
void displayStatus(const char* label, const char* value, uint16_t color);
void displayStatusLine(uint8_t row, const char* label, const char* value, uint16_t color);
void displayCoords(double lat, double lng);
void displaySleeping(uint32_t secs);
void displayError(const char* msg);
void displayBattery(float v);
uint8_t currentRow = 0;

// ======================================================================
//  SETUP
// ======================================================================
void setup() {
  // --- Avvio seriale ---
  Serial.begin(115200);
  Serial.println("\n--- Avvio Heltec Tracker (GPS + LoRaWAN + Display) ---");

  // --- Pin batteria ---
  pinMode(ADC_CTRL_PIN, OUTPUT);
  digitalWrite(ADC_CTRL_PIN, HIGH);

  // --- Accensione alimentazione esterna (GPS) ---
  pinMode(VEXT_PIN, OUTPUT);
  digitalWrite(VEXT_PIN, HIGH);

  // --- GPS RST: tieni HIGH per far funzionare il modulo ---
  pinMode(GPS_RST_PIN, OUTPUT);
  digitalWrite(GPS_RST_PIN, HIGH);

  // --- Retroilluminazione display ---
  pinMode(TFT_LED, OUTPUT);
  digitalWrite(TFT_LED, HIGH);

  // --- Inizializza display PRIMA di tutto il resto ---
  initDisplay();

  // --- Determina causa risveglio ---
  esp_sleep_wakeup_cause_t wakeup_reason = esp_sleep_get_wakeup_cause();
  if (wakeup_reason == ESP_SLEEP_WAKEUP_TIMER) {
    // Risveglio dal deep sleep
    
    // Aggiornamento bootCount
    bootCount++;
    
    // Stampa seriale
    Serial.println("Risveglio dal Deep Sleep.");
    
    // Aggiornamento display
    displayHeader(bootCount);
    displayStatusLine(0, "Avvio", "Risveglio", COLOR_GRAY);
  } else {
    // Avvio a freddo se è appena stato acceso
    
    // Stampa seriale
    Serial.println("Avvio a freddo.");
    
    // Aggiornamento variabili gps, radio e reset bootCount
    isJoined = false;
    bootCount = 0;
    has_last_fix = false;
    memset(lw_session, 0, sizeof(lw_session));
    memset(lw_nonces, 0, sizeof(lw_nonces));
    
    // Puntatore display
    displayHeader(0);
    
    // Aggiornamento display
    displayStatusLine(0, "Avvio", "Freddo", COLOR_WARN);
  }

  delay(500);
  
  // Inizializzazione seriale gps
  gpsSerial.begin(GPS_BAUD, SERIAL_8N1, RX_PIN, TX_PIN);

  // ---- 1. GPS ----
  // Aggiornamento display
  displayStatusLine(1, "GPS", "Ricerca...", COLOR_WARN);
  
  // Stampa seriale
  Serial.println("Ricerca segnale GPS in corso...");

  if (!getGpsFix()) {
    // Se l'antenna non riesce ad avere un fix

    // Stampa seriale
    Serial.println("Timeout GPS. Torno a dormire.");
    
    // Aggiornamento display
    displayStatusLine(1, "GPS", "Timeout!", COLOR_ERR);
    
    // Spegni display
    displaySleeping(SLEEP_TIME);
    
    // Deep sleep
    goToDeepSleep(SLEEP_TIME);
  }

  // Creazione variabili con le coordinate rilevate dal GPS
  double current_lat = gps.location.lat();
  double current_lng = gps.location.lng();

  // Stampa seriale
  Serial.printf("Fix: LAT=%.6f, LNG=%.6f\n", current_lat, current_lng);

  // Aggiornamento display
  displayStatusLine(1, "GPS", "Fix OK", COLOR_OK);
  displayCoords(current_lat, current_lng);

  // ---- 2. Spegni GPS ----

  // Spegnimento seriale gps
  gpsSerial.end();
  
  // Spegnimento alimentazione esterna per risparmiare energia
  digitalWrite(VEXT_PIN, LOW);
  delay(2000);

  // ---- 3. Controllo distanza ----
  if (has_last_fix) {
    // Se il gps ha una misurazione precedente

    // Calcolo distanza tra posizione attuale e ultima posizione salvata
    double distance = TinyGPSPlus::distanceBetween(current_lat, current_lng, last_lat, last_lng);
    
    // Stampa seriale
    Serial.printf("Distanza: %.2f m\n", distance);
    
    // Conversione distanza in stringa per il display
    char distStr[20];
    snprintf(distStr, sizeof(distStr), "%.1fm", distance);
    
    // Aggiornamento display con colore in base alla soglia minima
    displayStatusLine(4, "Distanza", distStr, distance >= MIN_DISTANCE_METERS ? COLOR_OK : COLOR_WARN);

    if (distance < MIN_DISTANCE_METERS) {
      // Se la distanza calcolata è minore della distanza minima voluta

      // Stampa seriale avviso
      Serial.println("Spostamento < 5m. Nessun invio.");
      
      // Aggiornamento display
      displayStatusLine(5, "LoRa", "Nessun invio", COLOR_WARN);

      // Spegnimento display
      displaySleeping(SLEEP_TIME);
      
      // Deep sleep
      goToDeepSleep(SLEEP_TIME);
    }
  } else {
    // Prima fix disponibile: nessun confronto possibile
    displayStatusLine(4, "Distanza", "Prima fix", COLOR_GRAY);
  }

  // ---- 4. Radio ----
  // Aggiornamento display
  displayStatusLine(5, "Radio", "Avvio...", COLOR_WARN);
  
  // Stampa seriale
  Serial.println("Avvio Radio LoRa...");
  
  // Apertura preferenze e avvio bus SPI per la radio
  preferences.begin("lorawan", false);
  hspi.begin(LORA_SCK, LORA_MISO, LORA_MOSI, -1);

  // Inizializzazione modulo radio
  int state = radio.begin();
  
  if (state != RADIOLIB_ERR_NONE) {
    // Se l'accensione della radio ritorna errori

    // Stampa seriale
    Serial.printf("Errore radio: %d\n", state);
    
    // Aggiornamento display
    displayStatusLine(5, "Radio", "Errore HW!", COLOR_ERR);
    
    // Spegnimento display
    displaySleeping(SLEEP_TIME);
    preferences.end();

    // Deep sleep
    goToDeepSleep(SLEEP_TIME);
  }

  // Configurazione radio: switch RF su DIO2 e modalità RX con guadagno aumentato
  radio.setDio2AsRfSwitch(true);
  radio.setRxBoostedGainMode(true);
  
  // Configurazione nodo LoRaWAN con credenziali OTAA
  node.beginOTAA(joinEUI, devEUI, nullptr, appKey);

  // ---- 5. Sessione / Join ----
  if (isJoined) {
    // Se è già stato fatto un join in precedenza

    // Aggiornamento display
    displayStatusLine(5, "LoRa", "Ripristino...", COLOR_WARN);
    
    // Stampa seriale
    Serial.println("Ripristino sessione da RTC...");
    
    // Caricamento dei buffer di sessione e nonces dalla RTC RAM
    node.setBufferNonces(lw_nonces);
    node.setBufferSession(lw_session);
    
    // Tentativo di ripristino della sessione OTAA
    state = node.activateOTAA();

    if (state == RADIOLIB_LORAWAN_SESSION_RESTORED) {
      // Se la sessione è ripristinata

      // Stampa seriale
      Serial.println("Sessione ripristinata.");
      
      // Aggiornamento display
      displayStatusLine(5, "LoRa", "Sessione OK", COLOR_OK);
    } else {
      // Se il ripristino fallisce

      // Stampa seriale
      Serial.printf("Ripristino fallito (%d). Re-join...\n", state);
      
      // Aggiornamento display
      displayStatusLine(5, "LoRa", "Re-join...", COLOR_WARN);
      
      // Reset del flag di join per forzare una nuova procedura
      isJoined = false;
    }
  }

  if (!isJoined) {
    // Se il join non è stato effettuato

    if (preferences.getBytesLength("nonces") == RADIOLIB_LORAWAN_NONCES_BUF_SIZE) {
      // Se le "nonces" sono presenti in memoria flash

      // Stampa seriale
      Serial.println("Carico nonces da flash.");

      // Caricamento "nonces" dalla flash e impostazione nel nodo
      preferences.getBytes("nonces", lw_nonces, RADIOLIB_LORAWAN_NONCES_BUF_SIZE);
      node.setBufferNonces(lw_nonces);
    }

    // Variabile per tenere il conto dei tentativi di join effettuati
    int joinAttempts = 0;
    do {
      // Preparazione stringa con numero tentativo corrente
      char attemptStr[20];
      snprintf(attemptStr, sizeof(attemptStr), "JOIN %d/5", joinAttempts + 1);
      
      // Aggiornamento display e stampa seriale
      displayStatusLine(5, "LoRa", attemptStr, COLOR_WARN);
      Serial.printf("JOIN OTAA tentativo %d...\n", joinAttempts + 1);

      // Tentativo di join OTAA
      state = node.activateOTAA();
      joinAttempts++;

      // Salvataggio delle nonces aggiornate in RTC RAM e flash dopo ogni tentativo
      memcpy(lw_nonces, node.getBufferNonces(), RADIOLIB_LORAWAN_NONCES_BUF_SIZE);
      preferences.putBytes("nonces", lw_nonces, RADIOLIB_LORAWAN_NONCES_BUF_SIZE);

      if (state != RADIOLIB_ERR_NONE) {
        // Se il tentativo di join è fallito

        // Stampa seriale e attesa prima del prossimo tentativo
        Serial.printf("JOIN fallito (%d). Attendo 5s...\n", state);
        delay(5000);
      }
    } while (state != RADIOLIB_ERR_NONE && joinAttempts < 5);

    if (state == RADIOLIB_ERR_NONE) {
      // Se il join è andato a buon fine

      // Stampa seriale
      Serial.println("JOIN COMPLETATO!");
      
      // Aggiornamento flag di join
      isJoined = true;
      
      // Salvataggio sessione e nonces in RTC RAM e flash
      memcpy(lw_session, node.getBufferSession(), RADIOLIB_LORAWAN_SESSION_BUF_SIZE);
      memcpy(lw_nonces, node.getBufferNonces(), RADIOLIB_LORAWAN_NONCES_BUF_SIZE);
      preferences.putBytes("nonces", lw_nonces, RADIOLIB_LORAWAN_NONCES_BUF_SIZE);
      
      // Aggiornamento display
      displayStatusLine(5, "LoRa", "JOIN OK!", COLOR_OK);
    } else {
      // Se tutti i tentativi di join sono falliti

      // Stampa seriale
      Serial.println("JOIN fallito definitivamente.");
      
      // Aggiornamento display
      displayStatusLine(5, "LoRa", "JOIN FAIL!", COLOR_ERR);
      
      // Spegnimento display e deep sleep prolungato per limitare i tentativi
      displaySleeping(60);
      preferences.end();
      goToDeepSleep(60);
    }
  }

  // ---- 6. Batteria ----

  // Lettura tensione batteria
  float batteryVoltage = readBattery();

  // Stampa seriale
  Serial.printf("Batteria: %.2fV\n", batteryVoltage);
  
  // Aggiornamento display con tensione letta
  displayBattery(batteryVoltage);

  // ---- 7. Payload e invio ----

  // Conversione coordinate in interi con 6 decimali di precisione (moltiplicati per 1.000.000)
  int32_t  lat_int     = (int32_t)(current_lat * 1000000);
  int32_t  lng_int     = (int32_t)(current_lng * 1000000);
  
  // Conversione tensione in centesimi di volt per ridurre la dimensione del payload
  uint16_t voltage_int = (uint16_t)(batteryVoltage * 100.0);

  // Costruzione payload da 12 byte in formato big-endian:
  // [0..3] latitudine | [4..7] longitudine | [8..9] bootCount | [10..11] tensione
  uint8_t payload[12];
  payload[0]  = (lat_int >> 24) & 0xFF;
  payload[1]  = (lat_int >> 16) & 0xFF;
  payload[2]  = (lat_int >> 8)  & 0xFF;
  payload[3]  =  lat_int        & 0xFF;
  payload[4]  = (lng_int >> 24) & 0xFF;
  payload[5]  = (lng_int >> 16) & 0xFF;
  payload[6]  = (lng_int >> 8)  & 0xFF;
  payload[7]  =  lng_int        & 0xFF;
  payload[8]  = (bootCount >> 8) & 0xFF;
  payload[9]  =  bootCount       & 0xFF;
  payload[10] = (voltage_int >> 8) & 0xFF;
  payload[11] =  voltage_int       & 0xFF;

  // Aggiornamento display
  displayStatusLine(6, "TX", "Invio...", COLOR_WARN);

  // Stampa seriale
  Serial.println("Invio payload...");

  // Invio payload sul canale 1, senza conferma (unconfirmed uplink)
  state = node.sendReceive(payload, sizeof(payload), 1, false);

  if (state == RADIOLIB_ERR_NONE || state == RADIOLIB_ERR_RX_TIMEOUT || state == 1) {
    // Se l'invio è andato a buon fine

    // Stampa seriale
    Serial.println("Pacchetto inviato.");

    // Aggiornamento display
    displayStatusLine(6, "TX", "Inviato OK", COLOR_OK);

    // Salvataggio sessione aggiornata in RTC RAM e flash dopo l'invio
    memcpy(lw_session, node.getBufferSession(), RADIOLIB_LORAWAN_SESSION_BUF_SIZE);
    memcpy(lw_nonces, node.getBufferNonces(), RADIOLIB_LORAWAN_NONCES_BUF_SIZE);
    preferences.putBytes("nonces", lw_nonces, RADIOLIB_LORAWAN_NONCES_BUF_SIZE);

    // Salvataggio posizione attuale come ultima posizione valida
    last_lat    = current_lat;
    last_lng    = current_lng;
    has_last_fix = true;

  } else {
    // Se l'invio non è andato a buon fine

    // Stampa seriale
    Serial.printf("Errore invio: %d\n", state);

    // Creazione stringa di errore con codice restituito dalla libreria
    char errStr[16];
    snprintf(errStr, sizeof(errStr), "Err: %d", state);

    // Aggiornamento display
    displayStatusLine(6, "TX", errStr, COLOR_ERR);

    // Reset del flag di join per forzare un nuovo join al prossimo ciclo
    isJoined = false;
  }

  // Chiusura preferenze flash
  preferences.end();

  // Spegnimento display
  displaySleeping(SLEEP_TIME);

  // Deep sleep
  goToDeepSleep(SLEEP_TIME);
}

void loop() {}

// ======================================================================
//  DISPLAY FUNCTIONS
// ======================================================================

void initDisplay() {
  // Avvio bus SPI dedicato al display (MISO non usato, impostato a -1)
  tftSpi.begin(TFT_SCLK, -1, TFT_MOSI, TFT_CS);
  
  // Inizializzazione driver ST7735S per pannello 160x80
  tft.initR(INITR_MINI160x80_PLUGIN);
  
  // Impostazione orientamento orizzontale (landscape): 160 wide, 80 tall
  tft.setRotation(3);
  
  // Pulizia schermo con colore di sfondo
  tft.fillScreen(COLOR_BG);
  
  // Disabilitazione a capo automatico del testo
  tft.setTextWrap(false);
  
  // Azzera il puntatore di riga corrente
  currentRow = 0;
}

// Intestazione fissa in cima
void displayHeader(uint16_t bootNum) {
  // Pulizia schermo
  tft.fillScreen(COLOR_BG);
  
  // Rettangolo di sfondo per la barra del titolo
  tft.fillRect(0, 0, 160, 13, 0x0211);
  
  // Stampa titolo del dispositivo
  tft.setTextColor(COLOR_TITLE);
  tft.setTextSize(1);
  tft.setCursor(3, 3);
  tft.print("Heltec Tracker");
  
  // Stampa numero di avvio in alto a destra
  tft.setTextColor(COLOR_GRAY);
  tft.setCursor(115, 3);
  char buf[10];
  snprintf(buf, sizeof(buf), "#%u", bootNum);
  tft.print(buf);
  
  // Linea separatrice sotto il titolo
  tft.drawFastHLine(0, 13, 160, COLOR_TITLE);
  
  // Azzera il puntatore di riga corrente
  currentRow = 0;
}

// Stampa una riga di stato: "Label    Value"
// row: 0..6  (7 righe disponibili sotto l'header, h=9px ciascuna)
void displayStatusLine(uint8_t row, const char* label, const char* value, uint16_t color) {
  // Calcolo coordinata Y in base al numero di riga
  uint8_t y = 16 + row * 9;
  
  // Cancella solo la riga da aggiornare per evitare flickering
  tft.fillRect(0, y, 160, 9, COLOR_BG);
  tft.setTextSize(1);
  
  // Stampa etichetta in grigio
  tft.setTextColor(COLOR_GRAY);
  tft.setCursor(2, y);
  tft.print(label);
  tft.print(":");
  
  // Stampa valore con il colore specificato dal chiamante
  tft.setTextColor(color);
  tft.setCursor(70, y);
  tft.print(value);
}

// Mostra coordinate su 2 righe (righe 2 e 3)
void displayCoords(double lat, double lng) {
  // Conversione coordinate in stringhe con 5 decimali
  char latStr[20], lngStr[20];
  snprintf(latStr, sizeof(latStr), "%.5f", lat);
  snprintf(lngStr, sizeof(lngStr), "%.5f", lng);
  
  // Visualizzazione su righe separate
  displayStatusLine(2, "LAT", latStr, COLOR_WHITE);
  displayStatusLine(3, "LNG", lngStr, COLOR_WHITE);
}

// Mostra voltaggio batteria con colore in base al livello
void displayBattery(float v) {
  // Formattazione tensione con 2 decimali
  char buf[16];
  snprintf(buf, sizeof(buf), "%.2fV", v);
  
  // Scelta del colore in base alle soglie di tensione
  uint16_t col = COLOR_OK;         // Verde: batteria carica (>= 3.7V)
  if (v < 3.5f)       col = COLOR_ERR;   // Rosso: batteria scarica
  else if (v < 3.7f)  col = COLOR_WARN;  // Giallo: batteria in esaurimento
  
  // Visualizzazione sulla riga extra in fondo al display
  displayStatusLine(7, "Batt", buf, col);
}

// Schermata "Vado a dormire" in fondo al display
void displaySleeping(uint32_t secs) {
  // Riga 7 (y=70) riservata al messaggio sleep con sfondo blu scuro
  tft.fillRect(0, 70, 160, 10, 0x0211);
  
  // Stampa messaggio con durata del deep sleep
  tft.setTextColor(COLOR_ORANGE);
  tft.setTextSize(1);
  tft.setCursor(2, 71);
  char buf[30];
  snprintf(buf, sizeof(buf), "Sleep %lus...", secs);
  tft.print(buf);
  
  // Pausa per rendere leggibile il messaggio prima dello spegnimento
  delay(1500);
}

// ======================================================================
//  GPS FIX
// ======================================================================
bool getGpsFix() {
  // Memorizza il tempo di inizio attesa
  unsigned long startWait = millis();
  
  // Variabili per la gestione dell'aggiornamento periodico del display
  uint32_t lastDot = 0;
  uint8_t  dots = 0;

  while (millis() - startWait < GPS_TIMEOUT_MS) {
    // Lettura e decodifica di tutti i byte disponibili dalla seriale GPS
    while (gpsSerial.available() > 0) {
      gps.encode(gpsSerial.read());
    }
    
    // Verifica se la posizione è valida e aggiornata
    if (gps.location.isValid() && gps.location.isUpdated()) {
      return true;
    }
    
    // Aggiornamento del display ogni secondo con numero di satelliti e tempo trascorso
    if (millis() - lastDot > 1000) {
      lastDot = millis();
      dots++;
      char satStr[20];
      uint32_t elapsed = (millis() - startWait) / 1000;
      snprintf(satStr, sizeof(satStr), "Sat:%d %us", gps.satellites.value(), elapsed);
      displayStatusLine(1, "GPS", satStr, COLOR_WARN);
    }
    
    // Piccola pausa per non saturare la CPU
    delay(10);
  }
  
  // Timeout raggiunto senza fix valido
  return false;
}

// ======================================================================
//  DEEP SLEEP
// ======================================================================
void goToDeepSleep(uint64_t sleepSeconds) {
  // Stampa seriale con durata del deep sleep
  Serial.printf("Deep Sleep per %llu s...\n", sleepSeconds);
  
  // Spegnimento retroilluminazione e disabilitazione display
  digitalWrite(TFT_LED, LOW);
  tft.enableDisplay(false);
  
  // Spegnimento alimentazione esterna (GPS e periferiche)
  digitalWrite(VEXT_PIN, LOW);
  
  // Messa in sleep del modulo radio per ridurre consumo
  radio.sleep();
  
  // Attesa svuotamento buffer seriale prima di dormire
  Serial.flush();
  
  // Configurazione timer di risveglio e avvio deep sleep
  esp_sleep_enable_timer_wakeup(sleepSeconds * uS_TO_S_FACTOR);
  esp_deep_sleep_start();
}

// ======================================================================
//  BATTERIA
// ======================================================================
float readBattery() {
  // Abilitazione del partitore ADC (pin LOW = misura attiva)
  digitalWrite(ADC_CTRL_PIN, LOW);
  delay(10);
  
  // Lettura tensione ADC in millivolt
  int adcValue_mV = analogReadMilliVolts(VBAT_PIN);
  
  // Disabilitazione del partitore ADC per ridurre consumo
  digitalWrite(ADC_CTRL_PIN, HIGH);
  
  // Correzione con il fattore del partitore resistivo Heltec (R1=390k, R2=100k → x4.9)
  return (adcValue_mV * 4.9f) / 1000.0f;
}