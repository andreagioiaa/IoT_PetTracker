#include <HardwareSerial.h>
#include "soc/usb_serial_jtag_reg.h"

// --- PIN LILYGO T-SIM7660G-S3 ---
#define MODEM_TX      11
#define MODEM_RX      10
#define MODEM_PWRKEY  18

#define PIN_EN        12
#define PIN_ADC_BAT   4
#define BAT_ADC_EN    14

const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/positions/records";
const char* apn    = "ibox.tim.it";

HardwareSerial modem(1);

struct BatInfo {
  float voltage;
  int   percent;
  bool  charging;
};

// Memoria persistente al Deep Sleep
RTC_DATA_ATTR bool  initialized = false;
RTC_DATA_ATTR float lastValidVoltage = 0.0f;
RTC_DATA_ATTR int   lastValidPercent = 0;

// Persistenza GPS per Hot Start
RTC_DATA_ATTR float lastLat = 0.0f;
RTC_DATA_ATTR float lastLon = 0.0f;
RTC_DATA_ATTR char  lastGpsDate[7] = ""; // ddmmyy
RTC_DATA_ATTR char  lastGpsTime[7] = ""; // hhmmss
RTC_DATA_ATTR bool  hasGpsFix = false;

String  sendAT(const char* cmd, uint32_t waitMs = 1500);
BatInfo leggiBatteria();
String  getTimestamp();
void    inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp);
bool    isUsbConnected();
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
    // Solo a batteria: voltaggio e percentuale sono affidabili
    bat.voltage = vFisico;
    bat.percent = constrain((int)((vFisico - 3.4f) / (4.2f - 3.4f) * 100), 0, 100);
    lastValidVoltage = vFisico;
    lastValidPercent = bat.percent;
  } else if (!bat.charging) {
    // A batteria ma lettura anomala: usa ultimi valori validi
    bat.voltage = lastValidVoltage;
    bat.percent = lastValidPercent;
  }
  // Se in carica: bat.voltage e bat.percent restano 0 (verranno inviati come null)

  return bat;
}

// ─────────────────────────────────────────────
String getTimestamp() {
  String r = sendAT("AT+CCLK?", 1500);
  int q1 = r.indexOf('"'), q2 = r.lastIndexOf('"');
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
void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp) {
  String json = "{";
  json += "\"timestamp\":\"";   json += timestamp;        json += "\",";
  json += "\"lat\":";           json += String(l_lat, 6); json += ",";
  json += "\"lon\":";           json += String(l_lon, 6); json += ",";
  json += "\"geo\":{\"lon\":";  json += String(l_lon, 6); json += ",";
  json += "\"lat\":";           json += String(l_lat, 6); json += "},";

  // Durante la carica USB: battery e battery_percent → null
  json += "\"battery\":";
  json += (!bat.charging && bat.voltage > 0.1f) ? String(bat.voltage, 2) : "null";
  json += ",";
  json += "\"battery_percent\":";
  json += (!bat.charging && bat.voltage > 0.1f) ? String(bat.percent) : "null";
  json += ",";
  json += "\"charging\":"; json += (bat.charging ? "true" : "false"); json += ",";
  json += "\"feet\":0";
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
void setup() {
  Serial.begin(115200);

  esp_sleep_wakeup_cause_t wakeup_reason = esp_sleep_get_wakeup_cause();

  // Se reset manuale o alimentazione, resetta inizializzazione
  if (wakeup_reason == ESP_SLEEP_WAKEUP_UNDEFINED) {
    delay(3000);
    initialized = false;
  }

  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);

  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, HIGH);

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);

  if (!initialized) {
    pinMode(MODEM_PWRKEY, OUTPUT);
    digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
    digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);
    delay(2000);

    Serial.println("\n=== PetTracker T-SIM7660G-S3 START (FIRST BOOT) ===");

    leggiBatteria();

    sendAT(("AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"").c_str());
    sendAT("AT+CNACT=0,1", 15000);
    sendAT("AT+CGDRT=4,1");
    sendAT("AT+CGSETV=4,1");
    sendAT("AT+CGNSSPWR=1");

    initialized = true;
  } else {
    Serial.println("\n=== PetTracker T-SIM7660G-S3 START (WAKEUP) ===");
    sendAT("AT+CGNSSPWR=1"); // Assicura che sia acceso
    iniettaGps();            // Inietta ultimi dati noti
  }

  Serial.println("=== SISTEMA PRONTO ===");
}

// ─────────────────────────────────────────────
void loop() {
  BatInfo bat = leggiBatteria();

  Serial.printf(bat.charging ? "IN CARICA (USB)" : "A BATTERIA", bat.voltage, bat.percent);

  String gps = sendAT("AT+CGNSSINFO", 1500);
  if (gps.indexOf("+CGNSSINFO:") != -1 && gps.indexOf(",,,,") == -1) {

    int pos = gps.indexOf(':');
    for (int i = 0; i < 5; i++) pos = gps.indexOf(',', pos + 1);
    int p6 = gps.indexOf(',', pos + 1);
    int p7 = gps.indexOf(',', p6 + 1);
    int p8 = gps.indexOf(',', p7 + 1);

    float lat = gps.substring(pos + 1, p6).toFloat();
    float lon = gps.substring(p7 + 1, p8).toFloat();

    if (lat != 0 && lon != 0) {
      String ts = getTimestamp();
      Serial.printf("[GPS] Fix OK: %.6f, %.6f\n", lat, lon);
      
      // Salva dati in RTC per prossimo wakeup
      lastLat = lat;
      lastLon = lon;
      hasGpsFix = true;
      
      // Estrae data/ora da AT+CCLK? via getTimestamp() logic or similar
      String r = sendAT("AT+CCLK?", 500);
      int q1 = r.indexOf('"');
      if (q1 != -1) {
        // Formato: "yy/mm/dd,hh:mm:ss+tz" -> ddmmyy, hhmmss
        String rawDate = r.substring(q1 + 7, q1 + 9) + r.substring(q1 + 4, q1 + 6) + r.substring(q1 + 1, q1 + 3);
        String rawTime = r.substring(q1 + 10, q1 + 12) + r.substring(q1 + 13, q1 + 15) + r.substring(q1 + 16, q1 + 18);
        strncpy(lastGpsDate, rawDate.c_str(), 6); lastGpsDate[6] = '\0';
        strncpy(lastGpsTime, rawTime.c_str(), 6); lastGpsTime[6] = '\0';
      }

      inviaDati(lat, lon, bat, ts);
    }
  } else {
    Serial.println("[GPS] No fix - wait...");
  }

  Serial.println("Entro in Deep Sleep per 30 secondi...");
  esp_sleep_enable_timer_wakeup(30ULL * 1000000ULL);
  esp_deep_sleep_start();
}