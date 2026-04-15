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

struct GpsData {
  float lat;
  float lon;
  bool  valid;
};

float lastValidVoltage = 0.0f;
int   lastValidPercent = 0;

String  sendAT(const char* cmd, uint32_t waitMs = 1500);
BatInfo leggiBatteria();
GpsData getGpsData();
String  getTimestamp();
void    inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp);
bool    isUsbConnected();

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
    bat.voltage = vFisico;
    bat.percent = constrain((int)((vFisico - 3.4f) / (4.2f - 3.4f) * 100), 0, 100);
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
  delay(3000);

  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);

  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, HIGH);

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  pinMode(MODEM_PWRKEY, OUTPUT);
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);

  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(2000);

  Serial.println("\n=== PetTracker T-SIM7670G-S3 START ===");

  leggiBatteria();

  sendAT(("AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"").c_str());
  sendAT("AT+CNACT=0,1", 15000);
  sendAT("AT+CGDRT=4,1");
  sendAT("AT+CGSETV=4,1");
  sendAT("AT+CGNSSPWR=1");

  Serial.println("=== SISTEMA PRONTO ===");
}

// ─────────────────────────────────────────────
void loop() {
  BatInfo bat = leggiBatteria();

  Serial.println(bat.charging ? "IN CARICA (USB)" : "A BATTERIA");

  GpsData gps = getGpsData();
  if (gps.valid) {
    String ts = getTimestamp();
    inviaDati(gps.lat, gps.lon, bat, ts);
  }

  delay(30000);
}