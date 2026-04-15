#include <Wire.h>
#include "SparkFun_BMA400_Arduino_Library.h"

// --- CONFIGURAZIONE HARDWARE (LilyGO T-SIM7670G S3) ---
BMA400 accelerometer;
const uint8_t I2C_ADDRESS = BMA400_I2C_ADDRESS_DEFAULT; // 0x14
const int I2C_SDA = 41;
const int I2C_SCL = 42;
const gpio_num_t WAKEUP_PIN = GPIO_NUM_5;

// --- PARAMETRI DI MONITORAGGIO ---
const unsigned long SLEEP_TIMEOUT = 12000; // 12 secondi senza passi per addormentarsi
uint32_t stepCountAtWakeup = 0;
unsigned long lastActivityTime = 0;

// Memoria RTC: non si cancella durante il Deep Sleep
RTC_DATA_ATTR int bootCount = 0;

void setup()
{
    Serial.begin(115200);
    delay(3000); // Finestra di sicurezza per i futuri caricamenti di codice
    
    bootCount++;
    Serial.printf("\n=== Avvio ESP32-S3 | Risveglio n. %d ===\n", bootCount);

    // 1. Inizializzazione I2C
    Wire.begin(I2C_SDA, I2C_SCL); 
    if (accelerometer.beginI2C(I2C_ADDRESS) != BMA400_OK) {
        Serial.println("ERRORE: BMA400 non trovato. Controlla i cavi I2C!");
        while(1); // Blocca l'esecuzione se il sensore non c'è
    }

    // 2. Configurazione Contapassi per il Risveglio
    // Inviamo il segnale del contapassi al pin fisico INT1 del sensore
    bma400_step_int_conf stepConfig = {
        .int_chan = BMA400_INT_CHANNEL_1 
    };
    accelerometer.setStepCounterInterrupt(&stepConfig);

    // Attiviamo l'interrupt dei passi (ignora le vibrazioni casuali)
    accelerometer.enableInterrupt(BMA400_STEP_COUNTER_INT_EN, true);
    
    // Disabilitiamo il sensore di movimento generico per evitare falsi risvegli
    accelerometer.enableInterrupt(BMA400_GEN1_INT_EN, false);

    // Impostiamo il pin INT1 come segnale "Alto" (3.3V) quando c'è un passo
    accelerometer.setInterruptPinMode(BMA400_INT_CHANNEL_1, BMA400_INT_PUSH_PULL_ACTIVE_1);

    // 3. Setup Variabili di Sessione
    uint8_t dummyActivity;
    accelerometer.getStepCount(&stepCountAtWakeup, &dummyActivity); // Salva i passi di partenza
    
    uint16_t dummyStatus = 0;
    accelerometer.getInterruptStatus(&dummyStatus); // Pulisce interrupt residui

    Serial.println("Sensore pronto: Mi sveglierò SOLO sui passi effettivi.");
    lastActivityTime = millis();
}

void loop()
{
    uint32_t currentTotalSteps = 0;
    uint8_t activityType = 0;
    static uint32_t lastSessionSteps = 0;

    // Leggi i passi e il tipo di attività in tempo reale
    accelerometer.getStepCount(&currentTotalSteps, &activityType);
    uint32_t sessionSteps = currentTotalSteps - stepCountAtWakeup;

    // --- LOGICA DI RILEVAMENTO ---
    // Se il numero di passi in questa sessione è aumentato
    if (sessionSteps > lastSessionSteps) 
    {
        lastActivityTime = millis(); // Resetta il timer di inattività
        lastSessionSteps = sessionSteps;
        
        Serial.print("➤ Passi sessione: ");
        Serial.print(sessionSteps);
        Serial.print("\t| Andatura: ");
        
        // Stampa la classificazione del movimento del BMA400
        switch(activityType) {
            case BMA400_RUN_ACT:
                Serial.println("Corsa");
                break;
            case BMA400_WALK_ACT:
                Serial.println("Camminata");
                break;
            case BMA400_STILL_ACT:
                Serial.println("Fermo");
                break;
            default:
                Serial.println("Sconosciuta");
                break;
        }
    }

    // --- LOGICA DI DEEP SLEEP ---
    // Se non ci sono nuovi passi per il tempo stabilito, torna a dormire
    if (millis() - lastActivityTime > SLEEP_TIMEOUT) 
    {
        Serial.println("\nAnimale fermo. Entro in modalità risparmio energetico (Deep Sleep)...");
        
        // Svuota l'interrupt per assicurarsi che il pin INT1 torni a 0V
        uint16_t status;
        do {
            accelerometer.getInterruptStatus(&status);
            delay(50);

        Serial.println("Buonanotte! Zzz...");
        delay(100);
        
        // Attiva la resistenza interna verso GND per evitare interferenze sul pin
        pinMode(WAKEUP_PIN, INPUT_PULLDOWN);

        // Configura il pin 05 per svegliare la scheda al prossimo segnale HIGH (prossimo passo)
        esp_sleep_enable_ext0_wakeup(WAKEUP_PIN, 1);

        // Spegnimento del processore
        esp_deep_sleep_start();
    }

    delay(150); // Piccolo ritardo per stabilità del ciclo
}

////



#include <Wire.h>
#include "SparkFun_BMA400_Arduino_Library.h"

// --- CONFIGURAZIONE HARDWARE (LilyGO T-SIM7670G S3) ---
BMA400 accelerometer;
const uint8_t I2C_ADDRESS = BMA400_I2C_ADDRESS_DEFAULT; // 0x14
const int I2C_SDA = 41;
const int I2C_SCL = 42;
const gpio_num_t WAKEUP_PIN = GPIO_NUM_5;

// --- PARAMETRI DI MONITORAGGIO ---
const unsigned long SLEEP_TIMEOUT = 12000;
uint32_t stepCountAtWakeup = 0;
unsigned long lastActivityTime = 0;

RTC_DATA_ATTR int bootCount = 0;

// ─────────────────────────────────────────────
struct StepData {
  uint32_t total;
  uint32_t session;
  uint8_t  activityType;
  bool     hasNewSteps;
};

// ─────────────────────────────────────────────
bool initAccelerometer() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (accelerometer.beginI2C(I2C_ADDRESS) != BMA400_OK) {
    Serial.println("ERRORE: BMA400 non trovato. Controlla i cavi I2C!");
    return false;
  }

  bma400_step_int_conf stepConfig = {
    .int_chan = BMA400_INT_CHANNEL_1
  };
  accelerometer.setStepCounterInterrupt(&stepConfig);
  accelerometer.enableInterrupt(BMA400_STEP_COUNTER_INT_EN, true);
  accelerometer.enableInterrupt(BMA400_GEN1_INT_EN, false);
  accelerometer.setInterruptPinMode(BMA400_INT_CHANNEL_1, BMA400_INT_PUSH_PULL_ACTIVE_1);

  uint8_t dummyActivity;
  accelerometer.getStepCount(&stepCountAtWakeup, &dummyActivity);

  uint16_t dummyStatus = 0;
  accelerometer.getInterruptStatus(&dummyStatus);

  return true;
}

// ─────────────────────────────────────────────
StepData readStepData(uint32_t lastSessionSteps) {
  StepData data = {0, 0, 0, false};

  accelerometer.getStepCount(&data.total, &data.activityType);
  data.session     = data.total - stepCountAtWakeup;
  data.hasNewSteps = (data.session > lastSessionSteps);

  return data;
}

// ─────────────────────────────────────────────
String activityLabel(uint8_t activityType) {
  switch (activityType) {
    case BMA400_RUN_ACT:   return "Corsa";
    case BMA400_WALK_ACT:  return "Camminata";
    case BMA400_STILL_ACT: return "Fermo";
    default:               return "Sconosciuta";
  }
}

// ─────────────────────────────────────────────
void enterDeepSleep() {
  Serial.println("\nAnimale fermo. Entro in modalità risparmio energetico (Deep Sleep)...");

  uint16_t status;
  do {
    accelerometer.getInterruptStatus(&status);
    delay(50);
  } while (digitalRead(WAKEUP_PIN) == HIGH);

  Serial.println("Buonanotte! Zzz...");
  delay(100);

  pinMode(WAKEUP_PIN, INPUT_PULLDOWN);
  esp_sleep_enable_ext0_wakeup(WAKEUP_PIN, 1);
  esp_deep_sleep_start();
}

// ─────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(3000);

  bootCount++;
  Serial.printf("\n=== Avvio ESP32-S3 | Risveglio n. %d ===\n", bootCount);

  if (!initAccelerometer()) {
    while (1); // Blocca se il sensore non risponde
  }

  Serial.println("Sensore pronto: Mi sveglierò SOLO sui passi effettivi.");
  lastActivityTime = millis();
}

// ─────────────────────────────────────────────
void loop() {
  static uint32_t lastSessionSteps = 0;

  StepData step = readStepData(lastSessionSteps);

  if (step.hasNewSteps) {
    lastActivityTime   = millis();
    lastSessionSteps   = step.session;

    Serial.print("➤ Passi sessione: ");
    Serial.print(step.session);
    Serial.print("\t| Andatura: ");
    Serial.println(activityLabel(step.activityType));
  }

  if (millis() - lastActivityTime > SLEEP_TIMEOUT) {
    enterDeepSleep();
  }

  delay(150);
}