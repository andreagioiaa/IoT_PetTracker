/*#include <HardwareSerial.h>

#define MODEM_TX      11 
#define MODEM_RX      10 
#define MODEM_PWRKEY  18
#define MODEM_POWERON  4 


HardwareSerial modemSerial(1);

unsigned long gpsStartTime = 0;
bool fixRicevuto = false;

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n--- GPS ATTIVO: FASE DI AGGANCIO ---");

  pinMode(MODEM_POWERON, OUTPUT);
  digitalWrite(MODEM_POWERON, HIGH); 
  pinMode(MODEM_PWRKEY, OUTPUT);
  
  modemSerial.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);

  digitalWrite(MODEM_PWRKEY, LOW);
  delay(100);
  digitalWrite(MODEM_PWRKEY, HIGH); 
  delay(1000); 
  digitalWrite(MODEM_PWRKEY, LOW);
  delay(5000); 

  sendAT("AT+CFUN=1");
  sendAT("AT+CGNSSPWR=1");
  sendAT("AT+CGNSSMODE=15");

  // ATTIVA IL FLUSSO DATI NMEA
  Serial.println("[!] Attivazione flusso NMEA... Vedrai scorrere i dati grezzi.");
  modemSerial.println("AT+CGNSTST=1");
  
  gpsStartTime = millis(); // Avvia il timer dopo la configurazione
  Serial.println("\n[!] Modem pronto. Mettiti all'aperto e attendi...");
  Serial.println("[TIMER] Ricerca satellites avviata.\n");
}

void loop() {
  modemSerial.println("AT+CGPSINFO");
  
  String resp = "";
  unsigned long start = millis();
  while (millis() - start < 1000) {
    while (modemSerial.available()) {
      resp += (char)modemSerial.read();
    }
  }

  // Calcola tempo trascorso
  unsigned long elapsed = millis() - gpsStartTime;
  unsigned long secondi = (elapsed / 1000) % 60;
  unsigned long minuti  = (elapsed / 60000) % 60;
  unsigned long ore     = elapsed / 3600000;

  char timerStr[20];
  sprintf(timerStr, "[%02lu:%02lu:%02lu]", ore, minuti, secondi);

  if (!fixRicevuto) {
    if (resp.indexOf(",,,,,,,,") != -1) {
      Serial.print(timerStr);
      Serial.println(" In ascolto... (Ancora nessun satellite trovato)");
    } else if (resp.indexOf("+CGPSINFO:") != -1) {
      fixRicevuto = true;

      Serial.println("\n>>> FIX RICEVUTO! <<<");
      Serial.print(timerStr);
      Serial.print(" Tempo per il primo fix: ");

      if (ore > 0) {
        Serial.print(ore);   Serial.print("h ");
      }
      if (minuti > 0) {
        Serial.print(minuti); Serial.print("m ");
      }
      Serial.print(secondi); Serial.println("s");
      Serial.println(resp);
    }
  } else {
    // Dopo il fix, continua a stampare i dati senza spam del timer
    if (resp.indexOf("+CGPSINFO:") != -1) {
      Serial.print(timerStr);
      Serial.println(" Aggiornamento GPS:");
      Serial.println(resp);
    }
  }

  delay(5000);
}

void sendAT(String cmd) {
  modemSerial.println(cmd);
  delay(500);
  while(modemSerial.available()) {
    Serial.write(modemSerial.read());
  }
}
*/

#include <HardwareSerial.h>

#define PIN_PWRKEY  18
#define PIN_EN      12  // Dalla tua immagine: EN 12
#define PIN_MODEM_PWR  4 // Dalla tua immagine: ADC/04 (spesso usato come power enable)
#define MODEM_TX    11
#define MODEM_RX    10

HardwareSerial modemSerial(1);

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n--- CONFIGURAZIONE HARDWARE LILYGO ---");

  // 1. ATTIVAZIONE ALIMENTAZIONE (Fondamentale per far reggere la batteria)
  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);    // Attiva il regolatore principale
  
  pinMode(PIN_MODEM_PWR, OUTPUT);
  digitalWrite(PIN_MODEM_PWR, HIGH); // Alimenta il modulo SIM
  
  delay(500); // Lasciamo stabilizzare la corrente

  // 2. ACCENSIONE MODEM (PWRKEY)
  pinMode(PIN_PWRKEY, OUTPUT);
  Serial.println("Accensione modem...");
  digitalWrite(PIN_PWRKEY, LOW);
  delay(1000); 
  digitalWrite(PIN_PWRKEY, HIGH);
  
  modemSerial.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  
  Serial.println("Attesa 5 secondi per inizializzazione...");
  delay(5000); 

  Serial.println("Attivazione LNA (Amplificatore Antenna)...");
modemSerial.println("AT+CVAUXS=1"); // Forza l'alimentazione all'antenna
delay(500);

Serial.println("Avvio GNSS...");
modemSerial.println("AT+CGNSSPWR=1");
delay(1000);
  
  Serial.println("Pronto! Ora scollega l'USB e vedi se resta accesa.");
}

void loop() {
  if (modemSerial.available()) Serial.write(modemSerial.read());
  if (Serial.available()) modemSerial.write(Serial.read());
  
  // Chiedi info ogni 5 secondi
  static unsigned long t = 0;
  if (millis() - t > 5000) {
    modemSerial.println("AT+CGNSSINFO");
    t = millis();
  }
}