#include <HardwareSerial.h>
#include "soc/usb_serial_jtag_reg.h"
#include <Wire.h>
#include "SparkFun_BMA400_Arduino_Library.h"

// ═══════════════════════════════════════════════
//  PIN LILYGO T-SIM7670G-S3
// ═══════════════════════════════════════════════
#define MODEM_TX      11
#define MODEM_RX      10
#define MODEM_PWRKEY  18
#define PIN_EN        12
#define PIN_ADC_BAT   4
#define BAT_ADC_EN    14

// ═══════════════════════════════════════════════
//  ACCELEROMETRO
// ═══════════════════════════════════════════════
BMA400 accelerometer;
const uint8_t    I2C_ADDRESS  = BMA400_I2C_ADDRESS_DEFAULT;
const int        I2C_SDA      = 41;
const int        I2C_SCL      = 42;
const gpio_num_t WAKEUP_PIN   = GPIO_NUM_5;

// Tempi (in millisecondi)
const unsigned long SLEEP_TIMEOUT = 30000;
const unsigned long NET_TIMEOUT   = 30000; // Max tempo per cercare la rete prima di arrendersi
const unsigned long GPS_TIMEOUT   = 20000; // Max tempo per fix GPS

// ═══════════════════════════════════════════════
//  MEMORIA PERSISTENTE (Sopravvive al Deep Sleep)
// ═══════════════════════════════════════════════
RTC_DATA_ATTR int   bootCount = 0;
RTC_DATA_ATTR float lastValidVoltage = 0.0f;
RTC_DATA_ATTR int   lastValidPercent = 0;
RTC_DATA_ATTR float lastLat = 0.0f;
RTC_DATA_ATTR float lastLon = 0.0f;
RTC_DATA_ATTR char  lastGpsDate[7] = "";
RTC_DATA_ATTR char  lastGpsTime[7] = ""; 
RTC_DATA_ATTR bool  hasGpsFix = false;
RTC_DATA_ATTR char  global_board_id[16] = "UNKNOWN";
RTC_DATA_ATTR uint32_t stepCountAtWakeup = 0;

// Variabili di sessione (non RTC)
unsigned long lastActivityTime  = 0;
bool isNetworkConnected = false;

// ═══════════════════════════════════════════════
//  MODEM / RETE (Configurazione VERY MOBILE)
// ═══════════════════════════════════════════════
const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/data_sent_raw/records";
const char* apn    = "ibox.tim.it"; // APN di Very Mobile "internet.it"

HardwareSerial modem(1);

// ═══════════════════════════════════════════════
//  STRUCT
// ═══════════════════════════════════════════════
struct BatInfo {
  float voltage;
  int   percent;
  bool  charging;
};

struct GpsData {
  float lat;
  float lon;
  bool  valid = false;
};

struct StepData {
  uint32_t total;
  uint32_t session;
  uint32_t lastSession = 0;
  uint8_t  activityType;
  bool     hasNewSteps;
};

// ═══════════════════════════════════════════════
//  FUNZIONI BASE E UTILITY
// ═══════════════════════════════════════════════
bool isUsbConnected() {
  return (READ_PERI_REG(USB_SERIAL_JTAG_EP1_CONF_REG) & USB_SERIAL_JTAG_SERIAL_IN_EP_DATA_FREE) != 0;
}

String sendAT(const char* cmd, uint32_t waitMs = 1500) {
  while (modem.available()) modem.read();
  modem.println(cmd);
  String resp = "";
  unsigned long t = millis();
  while (millis() - t < waitMs) {
    while (modem.available()) resp += (char)modem.read();
  }
  resp.trim();
  return resp;
}

String formatCoordinate(float val, bool isLat) {
  val = abs(val);
  int deg = (int)val;
  double min = (val - deg) * 60.0;
  char buf[32];
  if (isLat) sprintf(buf, "%02d%09.6f", deg, min);
  else       sprintf(buf, "%03d%09.6f", deg, min);
  return String(buf);
}

String getModemIMEI() {
  sendAT("AT+CGSN", 500); // Flush serial
  String resp = sendAT("AT+CGSN", 2000);
  resp.replace("AT+CGSN", ""); resp.replace("OK", ""); resp.replace("ERROR", ""); resp.trim();
  return (resp.length() >= 15) ? resp.substring(0, 15) : "UNKNOWN_IMEI";
}

// ═══════════════════════════════════════════════
//  BATTERIA
// ═══════════════════════════════════════════════
BatInfo leggiBatteria() {
  BatInfo bat = {0.0f, 0, false};
  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, HIGH);
  delay(50);
  uint32_t mv = 0;
  for (int i = 0; i < 10; i++) {
    mv += analogReadMilliVolts(PIN_ADC_BAT);
    delay(2);
  }
  mv /= 10;
  float vFisico = (mv * 2.0f) / 1000.0f;
  bat.charging = isUsbConnected();
  if (!bat.charging && vFisico > 3.0f) {
    bat.voltage      = vFisico;
    bat.percent      = constrain((int)((vFisico - 3.4f) / (4.2f - 3.4f) * 100), 0, 100);
    lastValidVoltage = vFisico;
    lastValidPercent = bat.percent;
  } else if (!bat.charging) {
    bat.voltage = lastValidVoltage;
    bat.percent = lastValidPercent;
  }
  digitalWrite(BAT_ADC_EN, LOW); // Spegni ADC subito dopo la lettura
  return bat;
}

// ═══════════════════════════════════════════════
//  RETE E CONNESSIONE FAST
// ═══════════════════════════════════════════════
bool connectToNetworkFast() {
  Serial.println("[NET] Configurazione Rapida VERY MOBILE...");
  
  // 1. Forza modalità LTE (Cat-1) per saltare la scansione lenta del 2G/3G
  sendAT("AT+CNMP=38", 1000); 
  
  // 2. Imposta l'APN di Very Mobile
  String apnCmd = "AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"";
  sendAT(apnCmd.c_str(), 1000);
  
  // 3. Avvia il contesto dati
  sendAT("AT+CNACT=0,1", 1000);

  Serial.println("[NET] Attesa registrazione rete...");
  unsigned long startWait = millis();
  
  while (millis() - startWait < NET_TIMEOUT) {
    String resp = sendAT("AT+CEREG?", 1000);
    if (resp.indexOf("0,1") != -1 || resp.indexOf("0,5") != -1) {
      Serial.println("[NET] Registrato in rete LTE con successo!");
      return true;
    }
    Serial.print(".");
  }
  
  Serial.println("\n[NET] Timeout rete! Segnale assente o troppo debole.");
  return false;
}

// ═══════════════════════════════════════════════
//  GPS
// ═══════════════════════════════════════════════
void iniettaGps() {
  if (!hasGpsFix) return;
  Serial.println("[GPS] Iniettando dati per Hot Start...");
  String latDir = (lastLat >= 0) ? "N" : "S";
  String lonDir = (lastLon >= 0) ? "E" : "W";
  String cmdPos = "AT+CGNSSPOS=" + formatCoordinate(lastLat, true) + "," + latDir + "," + 
                  formatCoordinate(lastLon, false) + "," + lonDir + ",0,100";
  sendAT(cmdPos.c_str(), 500);
  if (lastGpsDate[0] != '\0') {
    String cmdTime = "AT+CGNSSTIME=" + String(lastGpsDate) + "," + String(lastGpsTime) + ",1000";
    sendAT(cmdTime.c_str(), 500);
  }
}

GpsData getGpsData() {
  GpsData gps = {0.0f, 0.0f, false};
  String raw = sendAT("AT+CGNSSINFO", 1500);
  if (raw.indexOf("+CGNSSINFO:") == -1 || raw.indexOf(",,,,") != -1) return gps;
  
  int pos = raw.indexOf(':');
  for (int i = 0; i < 5; i++) pos = raw.indexOf(',', pos + 1);
  int p6 = raw.indexOf(',', pos + 1);
  int p7 = raw.indexOf(',', p6 + 1);
  int p8 = raw.indexOf(',', p7 + 1);
  
  float lat = raw.substring(pos + 1, p6).toFloat();
  float lon = raw.substring(p7 + 1, p8).toFloat();
  
  if (lat != 0 && lon != 0) {
    gps.lat = lat; gps.lon = lon; gps.valid = true;
  }
  return gps;
}

String getTimestamp() {
  String r  = sendAT("AT+CCLK?", 1000);
  int q1 = r.indexOf('"'), q2 = r.lastIndexOf('"');
  if (q1 == -1 || q2 == -1 || q2 <= q1) return "1970-01-01T00:00:00.000Z";
  String raw = r.substring(q1 + 1, q2);
  int hh = raw.substring(9, 11).toInt() + 2; // Correzione UTC+2
  if (hh >= 24) hh -= 24;
  
  String iso = "20" + raw.substring(0, 2) + "-" + raw.substring(3, 5) + "-" + raw.substring(6, 8) + "T";
  iso += (hh < 10 ? "0" : "") + String(hh) + ":" + raw.substring(12, 14) + ":" + raw.substring(15, 17) + ".000Z";
  return iso;
}

// ═══════════════════════════════════════════════
//  INVIO HTTP
// ═══════════════════════════════════════════════
void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp, const StepData& step, bool isSleeping) {
  String json = "{";
  json += "\"board_id\":\"" + String(global_board_id) + "\",";
  json += "\"timestamp\":\"" + timestamp + "\",";
  json += "\"lat\":" + String(l_lat, 6) + ",";
  json += "\"lon\":" + String(l_lon, 6) + ",";
  json += "\"geo\":{\"lon\":" + String(l_lon, 6) + ",\"lat\":" + String(l_lat, 6) + "},";
  json += "\"battery\":" + String((!bat.charging && bat.voltage > 0.1f) ? String(bat.voltage, 2) : "null") + ",";
  json += "\"battery_percent\":" + String((!bat.charging && bat.voltage > 0.1f) ? String(bat.percent) : "null") + ",";
  json += "\"charging\":" + String(bat.charging ? "true" : "false") + ",";
  json += "\"steps\":" + String(step.lastSession) + ",";
  json += "\"sleep\":" + String(isSleeping ? "true" : "false");
  json += "}";

  Serial.println("[JSON] " + json);

  sendAT("AT+HTTPINIT", 1000);
  sendAT(("AT+HTTPPARA=\"URL\",\"" + String(pb_url) + "\"").c_str(), 1000);
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"", 1000);
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"", 1000);
  
  String dataCmd = "AT+HTTPDATA=" + String(json.length()) + ",5000";
  sendAT(dataCmd.c_str(), 500);
  modem.print(json);
  delay(500);

  String res = sendAT("AT+HTTPACTION=1", 10000);
  Serial.print("[HTTP] "); Serial.println(res);
  sendAT("AT+HTTPTERM", 1000);
}

// ═══════════════════════════════════════════════
//  POWER MANAGEMENT
// ═══════════════════════════════════════════════
void enterDeepSleep() {
  Serial.println("\n[POWER] Spegnimento moduli e Deep Sleep...");
  
  sendAT("AT+CGNSSPWR=0"); // Spegne GPS (30mA)
  sendAT("AT+CPOWD=1");    // Spegnimento sicuro modem (Salva celle rete)
  delay(1000); 

  digitalWrite(PIN_EN, LOW);     // Togli alimentazione Modem
  digitalWrite(BAT_ADC_EN, LOW); // Togli alimentazione partitore ADC

  // Svuota buffer interrupt accelerometro
  uint16_t status;
  do { 
    accelerometer.getInterruptStatus(&status); 
    delay(50);
  } while (digitalRead(WAKEUP_PIN) == HIGH);

  esp_sleep_enable_ext0_wakeup(WAKEUP_PIN, 1);
  Serial.println("[POWER] Zzz...");
  Serial.flush();
  esp_deep_sleep_start();
}

bool initAccelerometer() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (accelerometer.beginI2C(I2C_ADDRESS) != BMA400_OK) return false;
  bma400_step_int_conf stepConfig = { .int_chan = BMA400_INT_CHANNEL_1 };
  accelerometer.setStepCounterInterrupt(&stepConfig);
  accelerometer.enableInterrupt(BMA400_STEP_COUNTER_INT_EN, true);
  accelerometer.setInterruptPinMode(BMA400_INT_CHANNEL_1, BMA400_INT_PUSH_PULL_ACTIVE_1);
  uint8_t dummy;
  accelerometer.getStepCount(&stepCountAtWakeup, &dummy);
  return true;
}

StepData readStepData(uint32_t lastSessionSteps) {
  StepData data = {0, 0, 0, 0, false};
  accelerometer.getStepCount(&data.total, &data.activityType);
  data.session     = data.total - stepCountAtWakeup;
  data.hasNewSteps = (data.session > lastSessionSteps);
  return data;
}

// ═══════════════════════════════════════════════
//  SETUP
// ═══════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  delay(1000);
  bootCount++;

  if (!initAccelerometer()) { Serial.println("ACC Error"); while(1); }

  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);
  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  pinMode(MODEM_PWRKEY, OUTPUT);
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);
  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(2000);

  // Identificazione Board
  if (strcmp(global_board_id, "UNKNOWN") == 0) {
    String imei = getModemIMEI();
    if (imei != "UNKNOWN_IMEI") imei.toCharArray(global_board_id, 16);
  }

  // Connessione Rapida alla Rete
  isNetworkConnected = connectToNetworkFast();

  // Se non c'è rete, inutile restare accesi a sprecare batteria
  if (!isNetworkConnected) {
    Serial.println("[SYS] Rete non disponibile. Ritorno in Deep Sleep immediato.");
    enterDeepSleep();
  }

  // Se c'è rete, accendiamo il GPS
  sendAT("AT+CGNSSPWR=1", 1000);
  sendAT("AT+CGDRT=4,1", 500); // Antenna GPS attiva (su board Lilygo)
  sendAT("AT+CGSETV=4,1", 500);
  
  if (hasGpsFix) iniettaGps();

  lastActivityTime = millis();
  Serial.println("=== SISTEMA PRONTO ===");
}

// ═══════════════════════════════════════════════
//  LOOP
// ═══════════════════════════════════════════════
void loop() {
  static uint32_t lastSessionStepsCount = 0;
  StepData step = readStepData(lastSessionStepsCount);
  BatInfo bat = leggiBatteria();

  // Fix GPS Rapido (con timeout)
  GpsData gps;
  unsigned long gpsStart = millis();
  Serial.println("[GPS] Ricerca segnale...");
  while(!gps.valid && (millis() - gpsStart < GPS_TIMEOUT)) { 
    gps = getGpsData();
    if (!gps.valid) delay(1000);
  }

  // Se ci siamo mossi
  if (step.hasNewSteps) {
    lastActivityTime = millis();
    step.lastSession = step.session - lastSessionStepsCount;
    lastSessionStepsCount = step.session;
    
    String ts = getTimestamp();
    
    // Salva le coordinate per la prossima accensione
    if(gps.valid) {
      lastLat = gps.lat; 
      lastLon = gps.lon; 
      hasGpsFix = true;
      String r = sendAT("AT+CCLK?", 500);
      int q1 = r.indexOf('"');
      if (q1 != -1) {
        String rawDate = r.substring(q1 + 7, q1 + 9) + r.substring(q1 + 4, q1 + 6) + r.substring(q1 + 1, q1 + 3);
        String rawTime = r.substring(q1 + 10, q1 + 12) + r.substring(q1 + 13, q1 + 15) + r.substring(q1 + 16, q1 + 18);
        strncpy(lastGpsDate, rawDate.c_str(), 6);
        strncpy(lastGpsTime, rawTime.c_str(), 6);
      }
    }

    inviaDati(gps.lat, gps.lon, bat, ts, step, false);
    
  } 
  // Se non ci muoviamo più, andiamo in sleep
  else if (millis() - lastActivityTime > SLEEP_TIMEOUT) {
    Serial.println("[SYSTEM] Timeout inattività. Invio stato 'Sleep' e chiusura.");
    String ts = getTimestamp();
    inviaDati(gps.lat, gps.lon, bat, ts, step, true);
    
    // Lascia al modem il tempo di finire la trasmissione HTTP prima di tagliare la corrente
    delay(2000); 
    enterDeepSleep();
  }

  delay(5000); // Intervallo a riposo tra i check del loop (quando non dorme)
}