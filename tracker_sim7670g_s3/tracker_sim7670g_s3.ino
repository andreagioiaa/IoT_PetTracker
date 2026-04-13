/*#include <HardwareSerial.h>

// --- PIN CONFIGURATION V1.1 ---
#define MODEM_TX      11
#define MODEM_RX      10
#define MODEM_PWRKEY  18
#define PIN_EN        12
#define PIN_ADC_BAT    4
#define BAT_ADC_EN    14 

// --- CONFIGURAZIONE SERVIZI ---
const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/positions/records";
const char* apn    = "ibox.tim.it";

HardwareSerial modem(1);

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

float leggiBatteria() {
  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, LOW); 
  delay(50);
  uint16_t raw = analogRead(PIN_ADC_BAT);
  float voltage = ((float)raw / 4095.0) * 2.0 * 3.3 * 1.1;
  digitalWrite(BAT_ADC_EN, HIGH); 
  return (voltage < 2.0) ? 0.0 : voltage;
}

void inviaDati(float l_lat, float l_lon, float l_volt) {
  // PocketBase accetta timestamp ISO8601. 
  // Se non hai l'ora esatta, usiamo una data fittizia o la data del GPS se disponibile.
  // Qui usiamo una stringa generica che PocketBase accetterà se il campo è String.
  
  String json = "{";
  json += "\"lat\":" + String(l_lat, 6) + ",";
  json += "\"lon\":" + String(l_lon, 6) + ",";
  json += "\"battery\":" + String(l_volt, 2) + ",";
  json += "\"timestamp\":\"2026-04-09 20:00:00.000Z\","; // Esempio ISO
  json += "\"geo\":{\"lat\":" + String(l_lat, 6) + ",\"lon\":" + String(l_lon, 6) + "}";
  json += "}";

  Serial.println("\n[HTTP] Invio Body: " + json);
  
  sendAT("AT+HTTPINIT");
  sendAT((String("AT+HTTPPARA=\"URL\",\"") + pb_url + "\"").c_str());
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"");
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"");

  String dataCmd = "AT+HTTPDATA=" + String(json.length()) + ",5000";
  sendAT(dataCmd.c_str(), 500);
  modem.print(json); 
  delay(500);

  String res = sendAT("AT+HTTPACTION=1", 8000);
  Serial.println("[MODEM] Risposta: " + res);
  
  sendAT("AT+HTTPTERM");
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_EN, OUTPUT); digitalWrite(PIN_EN, HIGH);
  pinMode(MODEM_PWRKEY, OUTPUT);
  
  // Accensione
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); 
  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(5000);

  // Rete TIM
  sendAT((String("AT+CGDCONT=1,\"IP\",\"") + apn + "\"").c_str());
  sendAT("AT+CNACT=0,1", 5000);
  
  // GPS
  sendAT("AT+CGDRT=4,1");
  sendAT("AT+CGSETV=4,1");
  sendAT("AT+CGNSSPWR=1");
}

void loop() {
  float vBat = leggiBatteria();
  String resp = sendAT("AT+CGNSSINFO", 1500);

  if (resp.indexOf("+CGNSSINFO:") != -1 && resp.indexOf(",,,,") == -1) {
    int pos = resp.indexOf(':');
    for(int i = 0; i < 5; i++) pos = resp.indexOf(',', pos + 1);
    int p6 = resp.indexOf(',', pos + 1);
    int p7 = resp.indexOf(',', p6 + 1);
    int p8 = resp.indexOf(',', p7 + 1);

    float lat = resp.substring(pos + 1, p6).toFloat();
    float lon = resp.substring(p7 + 1, p8).toFloat();

    inviaDati(lat, lon, vBat);
  }
  delay(20000);
}


--------------------------------------------------------------------------------------------



*/ 
#include <HardwareSerial.h>
#include "soc/usb_serial_jtag_reg.h"

// --- PIN LILYGO T-SIM7670G-S3 ---
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

// --- Ultimo stato valido (a batteria) ---
float lastValidVoltage = 0.0f;
int   lastValidPercent = -1;

// --- Prototipi ---
String  sendAT(const char* cmd, uint32_t waitMs = 1500);
BatInfo leggiBatteria();
String  getTimestamp();
void    inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp);
bool    isUsbConnected();

// ─────────────────────────────────────────────
bool isUsbConnected() {
  return (READ_PERI_REG(USB_SERIAL_JTAG_EP1_CONF_REG) 
          & USB_SERIAL_JTAG_SERIAL_IN_EP_DATA_FREE) != 0;
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

  // Stato USB
  bat.charging = isUsbConnected();

  // Leggi AT+CBC — valore già in Volt (es. "+CBC: 3.749V")
  String res = sendAT("AT+CBC", 500);
  float vModem = 0;
  int idx = res.indexOf("+CBC:");
  if (idx != -1) {
    String val = res.substring(idx + 5);
    val.trim();
    val.replace("V", "");
    val.trim();
    vModem = val.toFloat();
  }

  if (bat.charging) {
    // USB collegata: AT+CBC non è affidabile (power path)
    // Usa l'ultimo valore valido letto a batteria
    bat.voltage = lastValidVoltage;
    bat.percent = lastValidPercent;
  } else {
    // A batteria: lettura affidabile
    if (vModem > 3.0f) {
      bat.voltage = vModem;
      bat.percent = constrain((int)((vModem - 3.4f) / (4.2f - 3.4f) * 100), 0, 100);
      // Aggiorna l'ultimo valore valido
      lastValidVoltage = bat.voltage;
      lastValidPercent = bat.percent;
    } else {
      // Lettura non valida, usa ultimo noto
      bat.voltage = lastValidVoltage;
      bat.percent = lastValidPercent;
    }
  }

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
  json += "\"timestamp\":\"";   json += timestamp;              json += "\",";
  json += "\"lat\":";           json += String(l_lat, 6);       json += ",";
  json += "\"lon\":";           json += String(l_lon, 6);       json += ",";
  json += "\"geo\":{\"lon\":";  json += String(l_lon, 6);       json += ",";
  json += "\"lat\":";           json += String(l_lat, 6);       json += "},";
  json += "\"battery\":";
  json += (bat.voltage > 0) ? String(bat.voltage, 2) : "null";
  json += ",";
  json += "\"battery_percent\":";
  json += (bat.percent >= 0)  ? String(bat.percent)  : "null";
  json += ",";
  json += "\"charging\":";      json += (bat.charging ? "true" : "false");
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
  delay(2000);

  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);

  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, HIGH);

  analogSetAttenuation(ADC_11db);

  pinMode(MODEM_PWRKEY, OUTPUT);
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);

  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(2000);

  Serial.println("=== PetTracker T-SIM7670G-S3 START ===");

  sendAT(("AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"").c_str());
  sendAT("AT+CNACT=0,1", 15000);
  sendAT("AT+CGDRT=4,1");
  sendAT("AT+CGSETV=4,1");
  sendAT("AT+CGNSSPWR=1");

  Serial.println("=== TEST BATTERY MONITORING ===");
  sendAT("AT+CVALARM=1,3400,4200");
  sendAT("AT+CBC");
}

// ─────────────────────────────────────────────
void loop() {

  BatInfo bat = leggiBatteria();
  
  if (bat.charging) {
    Serial.printf("[BAT] In carica | Ultimo noto: %s | %s%%\n",
      bat.voltage > 0 ? String(bat.voltage, 2).c_str() : "n/d",
      bat.percent >= 0 ? String(bat.percent).c_str() : "n/d");
  } else {
    Serial.printf("[BAT] %.2fV | %d%% | A batteria\n",
      bat.voltage, bat.percent);
  }

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
      Serial.print("[GPS] ");
      Serial.print(lat, 6);
      Serial.print(" ");
      Serial.println(lon, 6);
      inviaDati(lat, lon, bat, ts);
    }
  } else {
    Serial.println("[GPS] No fix - wait...");
  }

  delay(30000);
}

/*

#include <HardwareSerial.h>

// ============================================================
//  PIN LILYGO T-SIM7670G-S3
// ============================================================
#define MODEM_TX      11
#define MODEM_RX      10
#define MODEM_PWRKEY  18
#define PIN_ADC_BAT    4
#define BAT_ADC_EN    12 

const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/positions/records";
const char* apn    = "ibox.tim.it";

HardwareSerial modem(1);

struct BatInfo {
  float voltage;
  int   percent;
  bool  charging;
};

struct GpsInfo {
  float  lat;
  float  lon;
  float  alt;
  bool   valid; 
  String timestamp;
};

// ============================================================
//  UTILITY AT
// ============================================================
String sendAT(const char* cmd, uint32_t waitMs = 1500) {
  while (modem.available()) modem.read();
  modem.println(cmd);
  String resp = "";
  unsigned long t = millis();
  while (millis() - t < waitMs) {
    while (modem.available()) resp += (char)modem.read();
  }
  resp.trim();
  if (resp.length() > 0) {
    Serial.print("[MODEM] "); Serial.println(resp);
  }
  return resp;
}

// ============================================================
//  BATTERIA
// ============================================================
int voltageToPercent(float v) {
  if (v >= 4.20f) return 100;
  if (v >= 4.00f) return 80;
  if (v >= 3.80f) return 60;
  if (v >= 3.60f) return 30;
  if (v >= 3.40f) return 5;
  return 0;
}

BatInfo leggiBatteria() {
  BatInfo bat = {0.0f, 0, false};
  digitalWrite(BAT_ADC_EN, HIGH);
  delay(20);
  uint32_t sum = 0;
  for (int i = 0; i < 30; i++) { sum += analogRead(PIN_ADC_BAT); delay(2); }
  float adcAvg = sum / 30.0f;
  bat.voltage = (adcAvg * 3.3f / 4095.0f) * 2.0f; 
  digitalWrite(BAT_ADC_EN, LOW);

  String res = sendAT("AT+CBC", 800);
  int idx = res.indexOf("+CBC:");
  if (idx != -1) {
    String sub = res.substring(idx + 5);
    int state = sub.substring(0, sub.indexOf(',')).toInt();
    bat.charging = (state == 1 || state == 2);
  }

  bat.percent = voltageToPercent(bat.voltage);
  Serial.printf("[BAT] V:%.3fV | %s | %d%%\n", bat.voltage, bat.charging ? "USB" : "BATT", bat.percent);
  return bat;
}

// ============================================================
//  TIMESTAMP
// ============================================================
String getTimestamp() {
  String r = sendAT("AT+CCLK?", 1000);
  int q1 = r.indexOf('"'), q2 = r.lastIndexOf('"');
  if (q1 == -1) return "2026-01-01T00:00:00.000Z";
  String raw = r.substring(q1 + 1, q2);
  char buf[30];
  snprintf(buf, sizeof(buf), "20%s-%s-%sT%s.000Z", 
           raw.substring(0,2).c_str(), raw.substring(3,5).c_str(), raw.substring(6,8).c_str(), raw.substring(9,17).c_str());
  return String(buf);
}

// ============================================================
//  GPS PARSING
// ============================================================
GpsInfo parseGNSS(const String& raw) {
  GpsInfo g = {0, 0, 0, false, ""};
  int hdr = raw.indexOf("+CGNSSINFO:");
  if (hdr == -1) return g;

  String data = raw.substring(hdr + 11);
  String tok[15];
  int count = 0, start = 0;
  for (int i = 0; i <= (int)data.length() && count < 15; i++) {
    if (i == (int)data.length() || data[i] == ',') {
      tok[count++] = data.substring(start, i);
      start = i + 1;
    }
  }

  if (count > 8 && tok[5].length() > 0) {
    g.lat = tok[5].toFloat();
    if (tok[6] == "S") g.lat = -g.lat;
    g.lon = tok[7].toFloat();
    if (tok[8] == "W") g.lon = -g.lon;
    if (count > 11) g.alt = tok[11].toFloat();
    g.timestamp = getTimestamp();
    g.valid = true;
  }
  return g;
}

// ============================================================
//  HTTP POST (JSON RIDOTTO)
// ============================================================
void inviaDati(const GpsInfo& gps, const BatInfo& bat) {
  String json = "{";
  json += "\"timestamp\":\"" + gps.timestamp + "\",";
  json += "\"lat\":" + String(gps.lat, 6) + ",";
  json += "\"lon\":" + String(gps.lon, 6) + ",";
  json += "\"geo\":{\"lon\":" + String(gps.lon, 6) + ",\"lat\":" + String(gps.lat, 6) + "},";
  json += "\"alt\":" + String(gps.alt, 1) + ",";
  json += "\"battery\":" + String(bat.voltage, 2) + ",";
  json += "\"battery_percent\":" + String(bat.percent) + ",";
  json += "\"charging\":" + String(bat.charging ? "true" : "false");
  json += "}";

  Serial.println("[HTTP-SEND] " + json);

  sendAT("AT+HTTPINIT");
  sendAT(("AT+HTTPPARA=\"URL\",\"" + String(pb_url) + "\"").c_str());
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"");
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"");
  sendAT(("AT+HTTPDATA=" + String(json.length()) + ",5000").c_str(), 500);
  modem.print(json);
  delay(500);
  sendAT("AT+HTTPACTION=1", 8000);
  sendAT("AT+HTTPTERM");
}

void setup() {
  Serial.begin(115200);
  delay(3000);
  Serial.println("\n--- PetTracker S3 Start ---");

  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  pinMode(BAT_ADC_EN, OUTPUT);
  pinMode(MODEM_PWRKEY, OUTPUT);
  analogSetAttenuation(ADC_11db);

  // Accensione
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(2000);
  digitalWrite(MODEM_PWRKEY, LOW);
  delay(4000);

  // NETWORK + GPS
  sendAT(("AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"").c_str());
  sendAT("AT+CNACT=0,1", 15000);
  sendAT("AT+CGDRT=4,1");
  sendAT("AT+CGSETV=4,1");
  sendAT("AT+CGNSSPWR=1");
}

void loop() {
  BatInfo b = leggiBatteria();
  String raw = sendAT("AT+CGNSSINFO", 1000);
  GpsInfo g = parseGNSS(raw);

  if (g.valid) {
    inviaDati(g, b);
  } else {
    Serial.println("[GPS] No Fix...");
  }
  delay(20000);
}
*/

