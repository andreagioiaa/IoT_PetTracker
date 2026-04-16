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

const unsigned long SLEEP_TIMEOUT = 30000;
uint32_t            stepCountAtWakeup = 0;
unsigned long       lastActivityTime  = 0;

RTC_DATA_ATTR int bootCount = 0;

// ═══════════════════════════════════════════════
//  MODEM / RETE
// ═══════════════════════════════════════════════
const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/positions/records";
const char* apn    = "ibox.tim.it";

HardwareSerial modem(1);

// ═══════════════════════════════════════════════
//  BATTERIA
// ═══════════════════════════════════════════════
RTC_DATA_ATTR float lastValidVoltage = 0.0f;
RTC_DATA_ATTR int   lastValidPercent = 0;

// ═══════════════════════════════════════════════
//  PERSISTENZA GPS (HOT START)
// ═══════════════════════════════════════════════
RTC_DATA_ATTR float lastLat = 0.0f;
RTC_DATA_ATTR float lastLon = 0.0f;
RTC_DATA_ATTR char  lastGpsDate[7] = ""; // ddmmyy
RTC_DATA_ATTR char  lastGpsTime[7] = ""; // hhmmss
RTC_DATA_ATTR bool  hasGpsFix = false;
RTC_DATA_ATTR bool  initialized = false;

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
  unit32_t lastSession = 0;
  uint8_t  activityType;
  bool     hasNewSteps;
};

// ═══════════════════════════════════════════════
//  PROTOTIPI
// ═══════════════════════════════════════════════
bool    isUsbConnected();
String  sendAT(const char* cmd, uint32_t waitMs = 1500);
BatInfo leggiBatteria();
GpsData getGpsData();
String  getTimestamp();
void    inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp, const StepData& step);
bool    initAccelerometer();
StepData readStepData(uint32_t lastSessionSteps);
String  activityLabel(uint8_t activityType);
void    enterDeepSleep();
void    iniettaGps();
String  formatCoordinate(float val, bool isLat);

// ─────────────────────────────────────────────
void iniettaGps() {
  if (!hasGpsFix) return;

  Serial.println("[GPS] Iniettando dati persistenti per Hot Start...");

  // Iniezione Posizione: AT+CGNSSPOS=<lat>,<lat_dir>,<lon>,<lon_dir>,<alt>,<uncertainty>
  String latDir = (lastLat >= 0) ? "N" : "S";
  String lonDir = (lastLon >= 0) ? "E" : "W";
  String cmdPos = "AT+CGNSSPOS=" + formatCoordinate(lastLat, true) + "," + latDir + "," + 
                  formatCoordinate(lastLon, false) + "," + lonDir + ",0,100";
                  
  sendAT(cmdPos.c_str());

  // Iniezione Tempo: AT+CGNSSTIME=<date>,<time>,<uncertainty>
  if (lastGpsDate[0] != '\0') {
    String cmdTime = "AT+CGNSSTIME=" + String(lastGpsDate) + "," + String(lastGpsTime) + ",1000";
    sendAT(cmdTime.c_str());
  }
}

// Converte gradi decimali in formato ddmm.mmmmmm (NMEA-style) richiesto per iniezione
String formatCoordinate(float val, bool isLat) {
  val = abs(val);
  int deg = (int)val;
  double min = (val - deg) * 60.0;
  char buf[32];
  if (isLat) sprintf(buf, "%02d%09.6f", deg, min);
  else       sprintf(buf, "%03d%09.6f", deg, min);
  return String(buf);
}

// ─────────────────────────────────────────────
bool isUsbConnected() {
  return (READ_PERI_REG(USB_SERIAL_JTAG_EP1_CONF_REG) & USB_SERIAL_JTAG_SERIAL_IN_EP_DATA_FREE) != 0;
}

// ─────────────────────────────────────────────
String sendAT(const char* cmd, uint32_t waitMs) {
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

// ─────────────────────────────────────────────
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

  return bat;
}

// ─────────────────────────────────────────────
GpsData getGpsData() {
  GpsData gps = {0.0f, 0.0f, false};

  String raw = sendAT("AT+CGNSSINFO", 1500);

  if (raw.indexOf("+CGNSSINFO:") == -1 || raw.indexOf(",,,,") != -1) {
    Serial.println("[GPS] No fix - wait...");
    return gps;
  }

  int pos = raw.indexOf(':');
  for (int i = 0; i < 5; i++) pos = raw.indexOf(',', pos + 1);
  int p6 = raw.indexOf(',', pos + 1);
  int p7 = raw.indexOf(',', p6 + 1);
  int p8 = raw.indexOf(',', p7 + 1);

  float lat = raw.substring(pos + 1, p6).toFloat();
  float lon = raw.substring(p7 + 1, p8).toFloat();

  if (lat == 0 || lon == 0) {
    Serial.println("[GPS] Fix invalido (0,0)");
    return gps;
  }

  gps.lat   = lat;
  gps.lon   = lon;
  gps.valid = true;

  Serial.printf("[GPS] Fix OK: %.6f, %.6f\n", lat, lon);
  return gps;
}

// ─────────────────────────────────────────────
String getTimestamp() {
  String r  = sendAT("AT+CCLK?", 1500);
  int    q1 = r.indexOf('"'), q2 = r.lastIndexOf('"');
  if (q1 == -1 || q2 == -1 || q2 <= q1) return "1970-01-01T00:00:00.000Z";

  String raw = r.substring(q1 + 1, q2);
  int hh = raw.substring(9, 11).toInt() + 2;
  if (hh >= 24) hh -= 24;

  String iso = "20";
  iso += raw.substring(0, 2); iso += "-";
  iso += raw.substring(3, 5); iso += "-";
  iso += raw.substring(6, 8); iso += "T";
  iso += (hh < 10 ? "0" : ""); iso += String(hh); iso += ":";
  iso += raw.substring(12, 14); iso += ":";
  iso += raw.substring(15, 17); iso += ".000Z";

  return iso;
}

// ─────────────────────────────────────────────
void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp, const StepData& step, bool sleep) {
  String json = "{";
  json += "\"timestamp\":\"";  json += timestamp;        json += "\",";
  json += "\"lat\":";          json += String(l_lat, 6); json += ",";
  json += "\"lon\":";          json += String(l_lon, 6); json += ",";
  json += "\"geo\":{\"lon\":"; json += String(l_lon, 6); json += ",";
  json += "\"lat\":";          json += String(l_lat, 6); json += "},";
  // batteria
  json += "\"battery\":";
  json += (!bat.charging && bat.voltage > 0.1f) ? String(bat.voltage, 2) : "null";
  json += ",";
  json += "\"battery_percent\":";
  json += (!bat.charging && bat.voltage > 0.1f) ? String(bat.percent) : "null";
  json += ",";
  json += "\"charging\":"; json += (bat.charging ? "true" : "false");
  json += ",";
  // feet
  json += "\"feet\":"; json += step.lastSession ; json += ",";
  // sleep
  json += "\"sleep\":"; json += sleep;
  json += "}";

  Serial.println("[JSON] " + json);

  sendAT("AT+HTTPINIT");
  sendAT(("AT+HTTPPARA=\"URL\",\"" + String(pb_url) + "\"").c_str());
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"");
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"");

  String dataCmd = "AT+HTTPDATA=" + String(json.length()) + ",5000";
  sendAT(dataCmd.c_str(), 500);
  modem.print(json);
  delay(500);

  String res = sendAT("AT+HTTPACTION=1", 10000);
  sendAT("AT+HTTPREAD=0,512", 3000);

  Serial.print("[HTTP] "); Serial.println(res);
  Serial.println("----------------------------------------");

  sendAT("AT+HTTPTERM");
}

// ─────────────────────────────────────────────
bool initAccelerometer() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (accelerometer.beginI2C(I2C_ADDRESS) != BMA400_OK) {
    Serial.println("ERRORE: BMA400 non trovato. Controlla i cavi I2C!");
    return false;
  }

  bma400_step_int_conf stepConfig = { .int_chan = BMA400_INT_CHANNEL_1 };
  accelerometer.setStepCounterInterrupt(&stepConfig);
  accelerometer.enableInterrupt(BMA400_STEP_COUNTER_INT_EN, true);
  accelerometer.enableInterrupt(BMA400_GEN1_INT_EN, false);
  accelerometer.setInterruptPinMode(BMA400_INT_CHANNEL_1, BMA400_INT_PUSH_PULL_ACTIVE_1);

  uint8_t  dummyActivity = 0;
  uint16_t dummyStatus   = 0;
  accelerometer.getStepCount(&stepCountAtWakeup, &dummyActivity);
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
  Serial.println("\nAnimale fermo. Entro in modalità risparmio energetico...");

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

// ═══════════════════════════════════════════════
//  SETUP
// ═══════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  delay(3000);

  esp_sleep_wakeup_cause_t wakeup_reason = esp_sleep_get_wakeup_cause();
  if (wakeup_reason == ESP_SLEEP_WAKEUP_UNDEFINED) {
    initialized = false;
  }

  bootCount++;
  Serial.printf("\n=== PetTracker T-SIM7670G-S3 | Avvio n. %d ===\n", bootCount);

  // Alimentazione
  pinMode(PIN_EN, OUTPUT);    digitalWrite(PIN_EN, HIGH);
  pinMode(BAT_ADC_EN, OUTPUT); digitalWrite(BAT_ADC_EN, HIGH);
  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  // Modem
  pinMode(MODEM_PWRKEY, OUTPUT);
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);
  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(2000);

  if (!initialized) {
    sendAT(("AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"").c_str());
    sendAT("AT+CNACT=0,1", 15000);
    sendAT("AT+CGDRT=4,1");
    sendAT("AT+CGSETV=4,1");
    sendAT("AT+CGNSSPWR=1");
    initialized = true;
  } else {
    sendAT("AT+CGNSSPWR=1");
    iniettaGps();
  }
  Serial.println("[MODEM] Pronto");

  // Accelerometro
  if (!initAccelerometer()) while (1);
  Serial.println("[ACC] Pronto - risveglio solo su passi effettivi");

  lastActivityTime = millis();
  Serial.println("=== SISTEMA PRONTO ===");
}

// ═══════════════════════════════════════════════
//  LOOP
// ═══════════════════════════════════════════════
void loop() {
  // Passi
  static uint32_t lastSessionSteps = 0;
  StepData step = readStepData(lastSessionSteps);

  // Batteria
  BatInfo bat = leggiBatteria();
  Serial.println(bat.charging ? "[BAT] IN CARICA (USB)" : "[BAT] A BATTERIA");

  // GPS
  GpsData gps;
  while(!gps.valid){
    gps = getGpsData();
  };

  if (step.hasNewSteps) {
    lastActivityTime  = millis();
    lastSessionSteps  = step.session;
    Serial.printf("[ACC] Passi sessione: %u | Andatura: %s\n", step.session, activityLabel(step.activityType).c_str());
    step.lastSession = step.session - step.lastSession;

    String ts = getTimestamp();
    
    // Aggiorna persistenza GPS
    lastLat = gps.lat;
    lastLon = gps.lon;
    hasGpsFix = true;
    
    // Estrae data/ora per iniezione futura
    String r = sendAT("AT+CCLK?", 500);
    int q1 = r.indexOf('"');
    if (q1 != -1) {
      String rawDate = r.substring(q1 + 7, q1 + 9) + r.substring(q1 + 4, q1 + 6) + r.substring(q1 + 1, q1 + 3);
      String rawTime = r.substring(q1 + 10, q1 + 12) + r.substring(q1 + 13, q1 + 15) + r.substring(q1 + 16, q1 + 18);
      strncpy(lastGpsDate, rawDate.c_str(), 6); lastGpsDate[6] = '\0';
      strncpy(lastGpsTime, rawTime.c_str(), 6); lastGpsTime[6] = '\0';
    }

    inviaDati(gps.lat, gps.lon, bat, ts, step , "false");
  } else if (millis() - lastActivityTime > SLEEP_TIMEOUT){
    Serial.println("[SYSTEM] Timeout inattività raggiunto. Invio dati finali...");
  
    String ts = getTimestamp();
    inviaDati(gps.lat, gps.lon, bat, ts, step, "true");
    
    delay(1000);
    enterDeepSleep();
  }

  delay(20000);
}