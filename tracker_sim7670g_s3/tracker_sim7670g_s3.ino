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

// --- PIN LILYGO T-SIM7670G-S3 ---
#define MODEM_TX      11
#define MODEM_RX      10
#define MODEM_PWRKEY  18
#define PIN_EN        12
#define PIN_ADC_BAT   4
#define BAT_ADC_EN    14

#define BATTERY_DIVIDER 2.0f
#define BATTERY_SAMPLES 10
#define BAT_MIN_VOLTAGE 2.00f

const char* pb_url = "https://harvey-chairless-shenna.ngrok-free.dev/api/collections/positions/records";
const char* apn    = "ibox.tim.it";

HardwareSerial modem(1);

struct BatInfo {
  float voltage;
  int   percent;
  bool  charging;
};

String sendAT(const char* cmd, uint32_t waitMs = 1500);
int voltageToPercent(float v);
BatInfo leggiBatteria();
String getTimestamp();
void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp);

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

int voltageToPercent(float v) {
  if (v >= 4.20f) return 100;
  if (v >= 4.15f) return 97;
  if (v >= 4.10f) return 92;
  if (v >= 4.05f) return 87;
  if (v >= 4.00f) return 80;
  if (v >= 3.90f) return 70;
  if (v >= 3.80f) return 60;
  if (v >= 3.70f) return 50;
  if (v >= 3.60f) return 35;
  if (v >= 3.50f) return 18;
  if (v >= 3.40f) return  8;
  if (v >= 3.30f) return  3;
  return 0;
}

BatInfo leggiBatteria() {
  BatInfo bat = {0.0f, 0, false};
  
  // 1. ATTIVAZIONE PARTITORE (Fondamentale su T-SIM7670G-S3)
  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, HIGH); 
  delay(20); // Tempo per stabilizzare la tensione sul pin ADC
  
  // 2. LETTURA ADC (GPIO 4)
  float adcSum = 0;
  for(int i = 0; i < 20; i++) { // Aumentati campioni per stabilità
    adcSum += analogRead(PIN_ADC_BAT);
    delay(2);
  }
  float adcAvg = adcSum / 20.0f;
  
  // Calcolo tensione: (ADC * Riferimento / Risoluzione) * Partitore
  // Su S3 il riferimento è circa 1.1V o 3.3V a seconda dell'attenuazione. 
  // Usiamo il calcolo standard per ESP32-S3:
  float batVoltageADC = (adcAvg * 3.3f / 4095.0f) * BATTERY_DIVIDER;
  
  // Spegniamo il partitore per risparmiare energia (opzionale)
  digitalWrite(BAT_ADC_EN, LOW); 

  // 3. CONTROLLO MODEM PER USB
  String r = sendAT("AT+CBC", 1000);
  bool modemCharging = false;
  
  // Analizziamo la risposta: +CBC: <bcs>,<bcl>,<voltage>
  int idx = r.indexOf("+CBC:");
  if (idx != -1) {
    String sub = r.substring(idx + 5);
    int firstComma = sub.indexOf(',');
    int status = sub.substring(0, firstComma).toInt();
    
    // Se status è 1 (in carica) o 2 (carica completa), USB è presente
    if (status == 1 || status == 2) {
      modemCharging = true;
    }
  }

  // 4. FALLBACK LOGICO
  // Se l'ADC legge 0, c'è un problema hardware o di pin.
  // Se batVoltageADC è molto alto (es > 4.3) mentre carica, è normale.
  bat.voltage = batVoltageADC;
  bat.charging = modemCharging;
  bat.percent = voltageToPercent(bat.voltage);
  
  // Se la tensione è troppo bassa ma siamo in USB, forza un valore minimo di visualizzazione
  if (bat.voltage < 2.0f && modemCharging) {
     Serial.println("[WARN] ADC legge 0 ma USB presente!");
  }

  Serial.printf("[BAT] ADC Raw: %.0f | V: %.2fV | USB: %s\n", 
                adcAvg, bat.voltage, bat.charging ? "SI" : "NO");
                
  return bat;
}

String getTimestamp() {
  String r = sendAT("AT+CCLK?", 1500);
  int q1 = r.indexOf('"'), q2 = r.lastIndexOf('"');
  if (q1 == -1 || q2 == -1 || q2 <= q1) return "1970-01-01T00:00:00.000Z";

  String raw = r.substring(q1 + 1, q2);
  int hh = raw.substring(9, 11).toInt() + 2;
  if (hh >= 24) hh -= 24;

  String iso = "20";
  iso += raw.substring(0,2); iso += "-";
  iso += raw.substring(3,5); iso += "-";
  iso += raw.substring(6,8); iso += "T";
  iso += (hh<10?"0":""); iso += String(hh); iso += ":";
  iso += raw.substring(12,14); iso += ":";
  iso += raw.substring(15,17); iso += ".000Z";
  
  return iso;
}

void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp) {
  // JSON su MULTIPLE linee (no errori sintassi)
  String json = "{";
  json += "\"timestamp\":\""; json += timestamp; json += "\",";
  json += "\"lat\":"; json += String(l_lat, 6); json += ",";
  json += "\"lon\":"; json += String(l_lon, 6); json += ",";
  json += "\"geo\":{\"lon\":"; json += String(l_lon, 6); json += ",";
  json += "\"lat\":"; json += String(l_lat, 6); json += "},";
  json += "\"battery\":"; json += String(bat.voltage, 2); json += ",";
  json += "\"battery_percent\":"; json += String(bat.percent); json += ",";
  json += "\"charging\":"; json += (bat.charging ? "true" : "false");
  json += "}";

  Serial.println("[JSON] " + json);
  
  // HTTP
  sendAT("AT+HTTPINIT");
  sendAT(("AT+HTTPPARA=\"URL\",\"" + String(pb_url) + "\"").c_str());
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"");
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"");

  String dataCmd = "AT+HTTPDATA=" + String(json.length()) + ",5000";
  sendAT(dataCmd.c_str(), 500);
  modem.print(json);
  delay(500);

  String res = sendAT("AT+HTTPACTION=1", 10000);
  String body = sendAT("AT+HTTPREAD=0,512", 3000);
  
  Serial.print("[HTTP] "); Serial.println(res);
  
  // LINEA SEPARATORE FISSA (NO repeat!)
  Serial.println("----------------------------------------");
  
  sendAT("AT+HTTPTERM");
}

void setup() {
  Serial.begin(115200);
  delay(2000);
  
  // Pin setup
  pinMode(PIN_EN, OUTPUT); digitalWrite(PIN_EN, HIGH);
  pinMode(BAT_ADC_EN, OUTPUT); digitalWrite(BAT_ADC_EN, LOW);

  analogSetAttenuation(ADC_11db);

  pinMode(MODEM_PWRKEY, OUTPUT);
  
  // Modem power
  digitalWrite(MODEM_PWRKEY, LOW); delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);
  
  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(2000);
  
  Serial.println("=== PetTracker T-SIM7670G-S3 START ===");
  
  // Network + GPS
  sendAT(("AT+CGDCONT=1,\"IP\",\"" + String(apn) + "\"").c_str());
  sendAT("AT+CNACT=0,1", 15000);
  sendAT("AT+CGDRT=4,1");
  sendAT("AT+CGSETV=4,1");
  sendAT("AT+CGNSSPWR=1");
}

void loop() {
  BatInfo bat = leggiBatteria();
  
  String gps = sendAT("AT+CGNSSINFO", 1500);
  if (gps.indexOf("+CGNSSINFO:") != -1 && gps.indexOf(",,,,") == -1) {
    
    // Parse GPS NMEA
    int pos = gps.indexOf(':');
    for (int i = 0; i < 5; i++) pos = gps.indexOf(',', pos + 1);
    int p6 = gps.indexOf(',', pos + 1);
    int p7 = gps.indexOf(',', p6 + 1);
    int p8 = gps.indexOf(',', p7 + 1);

    float lat = gps.substring(pos + 1, p6).toFloat();
    float lon = gps.substring(p7 + 1, p8).toFloat();

    if(lat != 0 && lon != 0) {
      String ts = getTimestamp();
      Serial.print("[GPS] "); 
      Serial.print(lat,6); 
      Serial.print(" "); 
      Serial.println(lon,6);
      inviaDati(lat, lon, bat, ts);
    }
  } else {
    Serial.println("[GPS] No fix - wait...");
  }
  
  delay(20000);
}
