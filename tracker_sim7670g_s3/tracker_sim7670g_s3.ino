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
*/


#include <HardwareSerial.h>

// --- PIN CONFIGURATION V1.1 ---
#define MODEM_TX      11
#define MODEM_RX      10
#define MODEM_PWRKEY  18
#define PIN_EN        12
#define PIN_ADC_BAT    4
#define BAT_ADC_EN    14

#define BAT_CHARGING_THRESHOLD  4.20f
#define BAT_MIN_VOLTAGE         2.00f

// --- CONFIGURAZIONE SERVIZI ---
const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/positions/records";
const char* apn    = "ibox.tim.it";

HardwareSerial modem(1);

// ─────────────────────────────────────────────────────────────
//  STRUCT — deve stare PRIMA di qualsiasi funzione che la usa,
//  altrimenti il preprocessore .ino genera prototipi errati.
// ─────────────────────────────────────────────────────────────
struct BatInfo {
  float voltage;
  bool  charging;
};

// ─────────────────────────────────────────────────────────────
//  AT helper
// ─────────────────────────────────────────────────────────────
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

// ─────────────────────────────────────────────────────────────
//  Batteria
// ─────────────────────────────────────────────────────────────
BatInfo leggiBatteria() {
  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, LOW);
  delay(50);
  uint16_t raw = analogRead(PIN_ADC_BAT);
  float voltage = ((float)raw / 4095.0f) * 2.0f * 3.3f * 1.1f;
  digitalWrite(BAT_ADC_EN, HIGH);

  if (voltage < BAT_MIN_VOLTAGE) voltage = 0.0f;

  // Charging dedotto dalla tensione.
  // Se hai un pin CHRG dal chip di ricarica (es. TP4054/MCP73831),
  // sostituisci con: bool charging = (digitalRead(PIN_CHRG) == LOW);
  bool charging = (voltage >= BAT_CHARGING_THRESHOLD);

  return { voltage, charging };
}

// ─────────────────────────────────────────────────────────────
//  Parsing timestamp da +CGNSSINFO
// ─────────────────────────────────────────────────────────────
String getTimestamp() {
  String r = sendAT("AT+CCLK?", 1500);
  int q1 = r.indexOf('"');
  int q2 = r.lastIndexOf('"');
  if (q1 == -1 || q2 == -1 || q2 <= q1) return "1970-01-01 00:00:00.000Z";

  String raw = r.substring(q1 + 1, q2);

  int hh = raw.substring(9, 11).toInt() + 2; // TIM dà UTC → aggiungi 2 per Italia
  if (hh >= 24) hh -= 24;

  String iso = "20" + raw.substring(0, 2) + "-"
             + raw.substring(3, 5) + "-"
             + raw.substring(6, 8) + " "
             + (hh < 10 ? "0" : "") + String(hh) + ":"
             + raw.substring(12, 14) + ":"
             + raw.substring(15, 17) + ".000+02:00";

  return iso;
}

// ─────────────────────────────────────────────────────────────
//  Invio HTTP verso PocketBase
//
//  Schema /positions:
//    timestamp : String  (ISO8601, REQUIRED)
//    lat       : Number
//    lon       : Number
//    geo       : Object  { "lon": x, "lat": y }
//    battery   : Number
//    charging  : Boolean
// ─────────────────────────────────────────────────────────────
void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp) {

  String json = "{";
  json += "\"timestamp\":\"" + timestamp + "\",";
  json += "\"lat\":"         + String(l_lat, 6) + ",";
  json += "\"lon\":"         + String(l_lon, 6) + ",";
  json += "\"geo\":{"
            "\"lon\":"       + String(l_lon, 6) + ","
            "\"lat\":"       + String(l_lat, 6) +
          "},";
  json += "\"battery\":"     + String(bat.voltage, 2) + ",";
  json += "\"charging\":"    + String(bat.charging ? "true" : "false");
  json += "}";

  // ── LOG DIMENSIONE PACCHETTO ─────────────────────────────
  int bodyBytes   = json.length();
  int headerBytes = String("POST ").length()
                  + strlen(pb_url)
                  + String(" HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: ").length()
                  + String(bodyBytes).length()
                  + String("\r\nngrok-skip-browser-warning: 1\r\n\r\n").length();
  int totalBytes  = headerBytes + bodyBytes;

  Serial.println("\n[PKT] Body:   " + String(bodyBytes)  + " bytes");
  Serial.println("[PKT] Header: " + String(headerBytes) + " bytes (stima)");
  Serial.println("[PKT] Tot:    " + String(totalBytes)  + " bytes (stima)");
  Serial.println("[HTTP] JSON: " + json);
  // ────────────────────────────────────────────────────────

  sendAT("AT+HTTPINIT");
  sendAT((String("AT+HTTPPARA=\"URL\",\"") + pb_url + "\"").c_str());
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"");
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"");

  String dataCmd = "AT+HTTPDATA=" + String(bodyBytes) + ",5000";
  sendAT(dataCmd.c_str(), 500);
  modem.print(json);
  delay(500);

  String res = sendAT("AT+HTTPACTION=1", 8000);
  Serial.println("[MODEM] Risposta HTTP: " + res);

  // Leggi il body della risposta PocketBase (utile per debug errori 4xx/5xx)
  String body = sendAT("AT+HTTPREAD=0,512", 3000);
  Serial.println("[MODEM] Body risposta: " + body);

  sendAT("AT+HTTPTERM");
}

// ─────────────────────────────────────────────────────────────
//  Setup
// ─────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  pinMode(PIN_EN, OUTPUT); digitalWrite(PIN_EN, HIGH);
  pinMode(MODEM_PWRKEY, OUTPUT);

  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH);
  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(5000);

  sendAT((String("AT+CGDCONT=1,\"IP\",\"") + apn + "\"").c_str());
  sendAT("AT+CNACT=0,1", 5000);

  sendAT("AT+CGDRT=4,1");
  sendAT("AT+CGSETV=4,1");
  sendAT("AT+CGNSSPWR=1");
}

// ─────────────────────────────────────────────────────────────
//  Loop
// ─────────────────────────────────────────────────────────────
void loop() {
  BatInfo bat  = leggiBatteria();
  String  resp = sendAT("AT+CGNSSINFO", 1500);

  Serial.println("[BAT] " + String(bat.voltage, 2) + "V  charging=" + String(bat.charging ? "YES" : "NO"));

  if (resp.indexOf("+CGNSSINFO:") != -1 && resp.indexOf(",,,,") == -1) {
    int pos = resp.indexOf(':');
    for (int i = 0; i < 5; i++) pos = resp.indexOf(',', pos + 1);
    int p6 = resp.indexOf(',', pos + 1);
    int p7 = resp.indexOf(',', p6 + 1);
    int p8 = resp.indexOf(',', p7 + 1);

    float lat = resp.substring(pos + 1, p6).toFloat();
    float lon = resp.substring(p7 + 1, p8).toFloat();

    String timestamp = getTimestamp();
    Serial.println("[GPS] lat=" + String(lat, 6) + " lon=" + String(lon, 6) + " ts=" + timestamp);

    inviaDati(lat, lon, bat, timestamp);
  } else {
    Serial.println("[GPS] Fix non disponibile, skip invio.");
  }

  delay(20000);
}