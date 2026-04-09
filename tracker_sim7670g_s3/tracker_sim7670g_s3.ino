#include <HardwareSerial.h>

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
  // Nota: PocketBase accetta timestamp ISO8601. 
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