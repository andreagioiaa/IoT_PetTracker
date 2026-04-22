// ═══════════════════════════════════════════════════════════════════════════════
//  TRACKER SIM7670G-S3 — con autenticazione JWT PocketBase
//  Versione con:
//    • Provisioning password via Serial (una-tantum)
//    • Token JWT salvato in NVS Flash (Preferences)
//    • Auto-refresh token se 401 o scaduto
//    • Coda pacchetti su NVS se rete assente
// ═══════════════════════════════════════════════════════════════════════════════

#include <HardwareSerial.h>
#include <Preferences.h>
#include "soc/usb_serial_jtag_reg.h"
#include <Wire.h>
#include "SparkFun_BMA400_Arduino_Library.h"

// ═══════════════════════════════════════════════
//  FORWARD DECLARATIONS
//  Necessarie perché il compilatore Arduino/g++
//  processa le funzioni nell'ordine del file.
//  Le funzioni di auth chiamano sendAT/isUsbConnected
//  che sono definite più in basso (Sezione 4).
// ═══════════════════════════════════════════════
String  sendAT(const char* cmd, uint32_t waitMs = 1500);
bool    isUsbConnected();
bool    inviaJsonHTTP(const String& json);  // per la ricorsione 401

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

// ═══════════════════════════════════════════════
//  BACKEND CONFIG
//  Username = IMEI (letto automaticamente dal modem)


// ═══════════════════════════════════════════════
const char* PB_BASE_URL   = "https://harvey-chairless-shenna.ngrok-free.dev";
const char* PB_AUTH_PATH  = "/api/collections/boards/auth-with-password";
const char* PB_DATA_PATH  = "/api/collections/data_sent_raw/records";
const char* APN           = "internet.it";
const char* BOARD_PASSWORD = "password"; // Cambia qui se la password cambia

// ─── Durata token: rinnova se mancano meno di TOKEN_REFRESH_MARGIN secondi ───
// PocketBase emette token JWT validi 7 giorni (604800s).
// Rinnoviamo se mancano meno di 12 ore (43200s) alla scadenza.
#define TOKEN_VALIDITY_SECONDS  604800UL   // 7 giorni
#define TOKEN_REFRESH_MARGIN    43200UL    // 12 ore prima della scadenza

// ═══════════════════════════════════════════════
//  TEMPI
// ═══════════════════════════════════════════════
const unsigned long SLEEP_TIMEOUT     = 60000;
const unsigned long NET_TIMEOUT       = 60000;
const unsigned long GPS_TIMEOUT       = 120000;
const unsigned long GPS_POLL_INTERVAL = 1000;
const unsigned long LOOP_INTERVAL     = 5000;

// ═══════════════════════════════════════════════
//  MEMORIA RTC (sopravvive al Deep Sleep)
// ═══════════════════════════════════════════════
RTC_DATA_ATTR int      bootCount          = 0;
RTC_DATA_ATTR int      netFailCount       = 0;
RTC_DATA_ATTR int      gpsFailCount       = 0;
RTC_DATA_ATTR float    lastValidVoltage   = 0.0f;
RTC_DATA_ATTR int      lastValidPercent   = 0;
RTC_DATA_ATTR float    lastLat            = 0.0f;
RTC_DATA_ATTR float    lastLon            = 0.0f;
RTC_DATA_ATTR char     lastGpsDate[7]     = "";
RTC_DATA_ATTR char     lastGpsTime[7]     = "";
RTC_DATA_ATTR bool     hasGpsFix          = false;
RTC_DATA_ATTR char     global_board_id[16]= "UNKNOWN";
RTC_DATA_ATTR uint32_t stepCountAtWakeup  = 0;

// ═══════════════════════════════════════════════
//  VARIABILI DI SESSIONE
// ═══════════════════════════════════════════════
unsigned long lastActivityTime = 0;
unsigned long lastGpsPollTime  = 0;
bool isNetworkConnected        = false;
int  previousNetFails          = 0;
Preferences prefs;
HardwareSerial modem(1);

// ═══════════════════════════════════════════════
//  STRUCT
// ═══════════════════════════════════════════════
struct BatInfo  { float voltage; int percent; bool charging; };
struct GpsData  { float lat; float lon; bool valid = false; };
struct StepData { uint32_t total; uint32_t session; uint32_t lastSession = 0; uint8_t activityType; bool hasNewSteps; };

// ═══════════════════════════════════════════════════════════════════════════════
//  SEZIONE 2 — AUTENTICAZIONE JWT
//
//  Il token viene salvato in NVS insieme al timestamp Unix di quando
//  è stato emesso (approssimato con millis() al boot — non perfetto
//  ma sufficiente per sapere se è "vecchio").
//  Per avere l'ora Unix reale usiamo il clock del modem (AT+CCLK?).
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Leggi epoch Unix dal modem (AT+CCLK?) ───────────────────────────────────
// Formato CCLK: "YY/MM/DD,HH:MM:SS±TZ"
// Ritorna 0 se non disponibile.
unsigned long modemEpoch() {
  String r = sendAT("AT+CCLK?", 1000);
  // cerca "24/05/10,08:30:00+08" dentro la risposta
  int q1 = r.indexOf('"');
  if (q1 == -1) return 0;
  String dt = r.substring(q1 + 1);

  int yr  = 2000 + dt.substring(0, 2).toInt();
  int mo  = dt.substring(3, 5).toInt();
  int dy  = dt.substring(6, 8).toInt();
  int hr  = dt.substring(9, 11).toInt();
  int mn  = dt.substring(12, 14).toInt();
  int sc  = dt.substring(15, 17).toInt();

  // Formula tm_to_epoch semplificata (ignora DST — tolleranza di ore è OK)
  // Giorni dall'epoca: approssimazione lineare sufficiente per token check
  static const int daysPerMonth[] = {0,31,59,90,120,151,181,212,243,273,304,334};
  long days = (yr - 1970) * 365L + (yr - 1969) / 4;
  days += daysPerMonth[mo - 1];
  if (mo > 2 && (yr % 4 == 0)) days++;
  days += dy - 1;

  return (unsigned long)days * 86400UL + hr * 3600UL + mn * 60UL + sc;
}

// ─── Carica token e timestamp da NVS ─────────────────────────────────────────
String loadToken() {
  prefs.begin("auth", true);  // read-only
  String t = prefs.getString("jwt_token", "");
  prefs.end();
  return t;
}

unsigned long loadTokenTimestamp() {
  prefs.begin("auth", true);
  unsigned long ts = prefs.getULong("jwt_ts", 0);
  prefs.end();
  return ts;
}

void saveToken(const String& token, unsigned long epochNow) {
  prefs.begin("auth", false);
  prefs.putString("jwt_token", token);
  prefs.putULong("jwt_ts", epochNow);
  prefs.end();
  Serial.println("[AUTH] Token salvato in NVS.");
}

// ─── Controlla se il token è ancora valido ───────────────────────────────────
bool isTokenValid(unsigned long epochNow) {
  String tok = loadToken();
  if (tok.length() == 0) return false;

  unsigned long ts = loadTokenTimestamp();
  if (ts == 0) return false;

  unsigned long age = epochNow - ts;
  unsigned long remaining = (age < TOKEN_VALIDITY_SECONDS) ? (TOKEN_VALIDITY_SECONDS - age) : 0;

  Serial.print("[AUTH] Token age: "); Serial.print(age);
  Serial.print("s  remaining: "); Serial.print(remaining); Serial.println("s");

  return remaining > TOKEN_REFRESH_MARGIN;
}

// ─── Estrai il token JWT dalla risposta HTTP PocketBase ──────────────────────
// PocketBase risponde con: {"token":"eyJ...","record":{...}}
String extractToken(const String& body) {
  int ti = body.indexOf("\"token\":\"");
  if (ti == -1) return "";
  int start = ti + 9;
  int end   = body.indexOf('"', start);
  if (end == -1) return "";
  return body.substring(start, end);
}

// ─── Login HTTP al PocketBase ────────────────────────────────────────────────
// Ritorna il token JWT oppure stringa vuota in caso di errore.
String doLogin() {
  String identity = String(global_board_id);
  String pw       = String(BOARD_PASSWORD);
  String json = "{\"identity\":\"" + identity + "\",\"password\":\"" + pw + "\"}";
  String url      = String(PB_BASE_URL) + String(PB_AUTH_PATH);

  Serial.println("[AUTH] Login → " + url);
  Serial.println("[AUTH] Body: " + json);

  sendAT("AT+HTTPTERM", 500);
  delay(300);
  sendAT("AT+HTTPINIT", 1000);
  sendAT(("AT+HTTPPARA=\"URL\",\"" + url + "\"").c_str(), 1000);
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"", 1000);
  sendAT("AT+HTTPPARA=\"USERDATA\",\"ngrok-skip-browser-warning: 1\"", 1000);

  // ── Invia body: aspetta il prompt DOWNLOAD prima di scrivere ────────────
  // Il modem risponde "DOWNLOAD" al comando HTTPDATA — solo allora
  // bisogna inviare i byte del body. sendAT() consumerebbe il prompt,
  // quindi gestiamo manualmente la sequenza.
  {
    String dataCmd = "AT+HTTPDATA=" + String(json.length()) + ",10000";
    while (modem.available()) modem.read(); // flush
    modem.println(dataCmd);

    // Aspetta "DOWNLOAD" (max 3s)
    String prompt = "";
    unsigned long t0 = millis();
    while (millis() - t0 < 3000) {
      while (modem.available()) prompt += (char)modem.read();
      if (prompt.indexOf("DOWNLOAD") != -1) break;
      delay(10);
    }
    Serial.println("[AUTH] HTTPDATA prompt: " + prompt);

    if (prompt.indexOf("DOWNLOAD") == -1) {
      Serial.println("[AUTH] Nessun prompt DOWNLOAD. Invio abortito.");
      sendAT("AT+HTTPTERM", 500);
      return "";
    }

    // Ora invia il body JSON
    modem.print(json);
    delay(200);

    // Aspetta OK dopo l'invio del body (max 3s)
    String ack = "";
    unsigned long t1 = millis();
    while (millis() - t1 < 3000) {
      while (modem.available()) ack += (char)modem.read();
      if (ack.indexOf("OK") != -1 || ack.indexOf("ERROR") != -1) break;
      delay(10);
    }
    Serial.println("[AUTH] HTTPDATA ack: " + ack);
  }

  // ── POST ────────────────────────────────────────────────────────────────
  String res = sendAT("AT+HTTPACTION=1", 15000);
  Serial.print("[AUTH] HTTP Result: "); Serial.println(res);

  int statusCode = 0;
  int bodyLen    = 0;
  {
    int commaA = res.indexOf(',');
    int commaB = res.indexOf(',', commaA + 1);
    if (commaA != -1 && commaB != -1) {
      statusCode = res.substring(commaA + 1, commaB).toInt();
      bodyLen    = res.substring(commaB + 1).toInt();
    }
  }

  Serial.print("[AUTH] Status: "); Serial.print(statusCode);
  Serial.print("  BodyLen: "); Serial.println(bodyLen);

  if (statusCode != 200 || bodyLen == 0) {
    Serial.println("[AUTH] Login fallito (HTTP " + String(statusCode) + ").");
    sendAT("AT+HTTPTERM", 500);
    return "";
  }

  // ── Leggi body ──────────────────────────────────────────────────────────
  String readCmd = "AT+HTTPREAD=0," + String(min(bodyLen, 1460));
  String body    = sendAT(readCmd.c_str(), 5000);
  sendAT("AT+HTTPTERM", 500);

  Serial.println("[AUTH] Body: " + body);

  String token = extractToken(body);
  if (token.length() == 0) {
    Serial.println("[AUTH] Token non trovato nel body.");
    return "";
  }

  Serial.println("[AUTH] Token OK (" + String(token.length()) + " chars).");
  return token;
}

// ─── Punto di accesso principale: garantisce token valido ───────────────────
// Ritorna true se abbiamo un token pronto, false se impossibile autenticarsi.
bool ensureValidToken() {
  unsigned long now = modemEpoch();
  Serial.print("[AUTH] Epoch corrente: "); Serial.println(now);

  if (now > 0 && isTokenValid(now)) {
    Serial.println("[AUTH] Token valido, uso quello salvato.");
    return true;
  }

  Serial.println("[AUTH] Token assente o in scadenza. Rinnovo...");
  String newToken = doLogin();
  if (newToken.length() == 0) return false;

  // Se modemEpoch() ha fallito, usiamo 0 come timestamp di fallback
  // (il token verrà rivalidato al prossimo boot quando il clock è disponibile)
  saveToken(newToken, now);
  return true;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SEZIONE 3 — INVIO HTTP AUTENTICATO
//
//  SIM7670G supporta un solo header custom via HTTPPARA="USERDATA".
//  Siccome ne abbiamo già uno (ngrok), concateniamo gli header
//  separandoli con \r\n come da specifica AT SIMCOM.
// ═══════════════════════════════════════════════════════════════════════════════
bool inviaJsonHTTP(const String& json) {
  String token = loadToken();
  String url   = String(PB_BASE_URL) + String(PB_DATA_PATH);

  sendAT("AT+HTTPTERM", 500);
  delay(200);
  sendAT("AT+HTTPINIT", 1000);
  sendAT(("AT+HTTPPARA=\"URL\",\"" + url + "\"").c_str(), 1000);
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"", 1000);

  // Costruisci USERDATA con Authorization + header ngrok
  // Il separatore tra header multipli è \r\n (CRLF raw nella stringa AT)
  String userdata = "Authorization: Bearer " + token;
  userdata += "\r\nngrok-skip-browser-warning: 1";
  sendAT(("AT+HTTPPARA=\"USERDATA\",\"" + userdata + "\"").c_str(), 1000);

  // ── Invia body: aspetta prompt DOWNLOAD ────────────────────────────────
  {
    String dataCmd = "AT+HTTPDATA=" + String(json.length()) + ",10000";
    while (modem.available()) modem.read();
    modem.println(dataCmd);

    String prompt = "";
    unsigned long t0 = millis();
    while (millis() - t0 < 3000) {
      while (modem.available()) prompt += (char)modem.read();
      if (prompt.indexOf("DOWNLOAD") != -1) break;
      delay(10);
    }
    if (prompt.indexOf("DOWNLOAD") == -1) {
      Serial.println("[HTTP] Nessun prompt DOWNLOAD.");
      sendAT("AT+HTTPTERM", 500);
      return false;
    }
    modem.print(json);
    delay(200);
    // Aspetta OK
    unsigned long t1 = millis();
    String ack = "";
    while (millis() - t1 < 3000) {
      while (modem.available()) ack += (char)modem.read();
      if (ack.indexOf("OK") != -1 || ack.indexOf("ERROR") != -1) break;
      delay(10);
    }
  }

  String res = sendAT("AT+HTTPACTION=1", 15000);
  Serial.print("[HTTP] "); Serial.println(res);

  // Estrai status code e lunghezza body
  int statusCode = 0;
  int bodyLen = 0;
  {
    int commaA = res.indexOf(',');
    int commaB = res.indexOf(',', commaA + 1);
    if (commaA != -1 && commaB != -1) {
      statusCode = res.substring(commaA + 1, commaB).toInt();
      bodyLen = res.substring(commaB + 1).toInt();
    }
  }

  // Se c'è un errore 400, leggi il messaggio di PocketBase prima di chiudere
  if (statusCode == 400 && bodyLen > 0) {
      String readCmd = "AT+HTTPREAD=0," + String(min(bodyLen, 1460));
      String errorBody = sendAT(readCmd.c_str(), 2000);
      Serial.println("[HTTP] Errore da PocketBase: " + errorBody);
  }

  sendAT("AT+HTTPTERM", 500);

  // ── 401 → token scaduto: rinnova e riprova una volta ─────────────────────
  if (statusCode == 401) {
    Serial.println("[HTTP] 401 Unauthorized — rinnovo token e riprovo.");
    // Invalida il token in NVS (timestamp = 0 forza rinnovo)
    prefs.begin("auth", false);
    prefs.putULong("jwt_ts", 0);
    prefs.end();

    if (!ensureValidToken()) {
      Serial.println("[HTTP] Impossibile rinnovare il token. Salvo in coda.");
      return false;
    }
    // Riprova invio (ricorsione singola — no loop infinito)
    return inviaJsonHTTP(json);
  }

  // 2xx = successo
  bool ok = (statusCode >= 200 && statusCode < 300);
  if (!ok) {
    Serial.print("[HTTP] Errore HTTP: "); Serial.println(statusCode);
  }
  return ok;
}

// ═══════════════════════════════════════════════
//  SEZIONE 4 — UTILITY (invariate dall'originale)
// ═══════════════════════════════════════════════
bool isUsbConnected() {
  return (READ_PERI_REG(USB_SERIAL_JTAG_EP1_CONF_REG) & USB_SERIAL_JTAG_SERIAL_IN_EP_DATA_FREE) != 0;
}

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
  sendAT("AT+CGSN", 500);
  String resp = sendAT("AT+CGSN", 2000);
  resp.replace("AT+CGSN", ""); resp.replace("OK", ""); resp.replace("ERROR", ""); resp.trim();
  return (resp.length() >= 15) ? resp.substring(0, 15) : "UNKNOWN_IMEI";
}

BatInfo leggiBatteria() {
  BatInfo bat = {0.0f, 0, false};
  pinMode(BAT_ADC_EN, OUTPUT);
  digitalWrite(BAT_ADC_EN, HIGH);
  delay(50);
  uint32_t mv = 0;
  for (int i = 0; i < 10; i++) { mv += analogReadMilliVolts(PIN_ADC_BAT); delay(2); }
  mv /= 10;
  float vFisico = (mv * 2.0f) / 1000.0f;
  bat.charging = isUsbConnected();
  if (!bat.charging && vFisico > 3.0f) {
    bat.voltage = vFisico;
    bat.percent = constrain((int)((vFisico - 3.4f) / (4.2f - 3.4f) * 100), 0, 100);
    lastValidVoltage = vFisico; lastValidPercent = bat.percent;
  } else if (!bat.charging) {
    bat.voltage = lastValidVoltage; bat.percent = lastValidPercent;
  }
  digitalWrite(BAT_ADC_EN, LOW);
  return bat;
}

bool connectToNetworkFast() {
  Serial.println("[NET] Configurazione Rapida ISP...");
  sendAT("AT+CNMP=38", 1000);
  String apnCmd = "AT+CGDCONT=1,\"IP\",\"" + String(APN) + "\"";
  sendAT(apnCmd.c_str(), 1000);
  sendAT("AT+CNACT=0,1", 1000);
  Serial.println("[NET] Attesa registrazione rete...");
  unsigned long startWait = millis();
  while (millis() - startWait < NET_TIMEOUT) {
    String resp = sendAT("AT+CEREG?", 1000);
    if (resp.indexOf("0,1") != -1 || resp.indexOf("0,5") != -1) {
      Serial.println("[NET] Registrato in rete LTE!");
      return true;
    }
    Serial.print(".");
  }
  Serial.println("\n[NET] Timeout rete.");
  return false;
}

void iniettaGps() {
  if (!hasGpsFix) return;
  String latDir = (lastLat >= 0) ? "N" : "S";
  String lonDir = (lastLon >= 0) ? "E" : "W";
  String cmdPos = "AT+CGNSSPOS=" + formatCoordinate(lastLat, true) + "," + latDir + "," + formatCoordinate(lastLon, false) + "," + lonDir + ",0,100";
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
  if (lat != 0.0f && lon != 0.0f) { gps.lat = lat; gps.lon = lon; gps.valid = true; }
  return gps;
}

void salvaDataOraGps() {
  String r = sendAT("AT+CCLK?", 500);
  int q1 = r.indexOf('"');
  if (q1 == -1) return;
  String rawDate = r.substring(q1 + 7, q1 + 9) + r.substring(q1 + 4, q1 + 6) + r.substring(q1 + 1, q1 + 3);
  String rawTime = r.substring(q1 + 10, q1 + 12) + r.substring(q1 + 13, q1 + 15) + r.substring(q1 + 16, q1 + 18);
  strncpy(lastGpsDate, rawDate.c_str(), 6);
  strncpy(lastGpsTime, rawTime.c_str(), 6);
}

String getTimestamp() {
  String r  = sendAT("AT+CCLK?", 1000);
  int q1 = r.indexOf('"'), q2 = r.lastIndexOf('"');
  if (q1 == -1 || q2 == -1 || q2 <= q1) return "1970-01-01T00:00:00.000Z";
  String raw = r.substring(q1 + 1, q2);
  int hh = raw.substring(9, 11).toInt() + 2;
  if (hh >= 24) hh -= 24;
  String iso = "20" + raw.substring(0, 2) + "-" + raw.substring(3, 5) + "-" + raw.substring(6, 8) + "T";
  iso += (hh < 10 ? "0" : "") + String(hh) + ":" + raw.substring(12, 14) + ":" + raw.substring(15, 17) + ".000Z";
  return iso;
}

// ═══════════════════════════════════════════════
//  SEZIONE 5 — CODA PACCHETTI NVS
// ═══════════════════════════════════════════════
#define MAX_QUEUED_PACKETS 10

void salvaInCoda(const String& json) {
  prefs.begin("pkt_queue", false);
  int count = prefs.getInt("count", 0);
  if (count >= MAX_QUEUED_PACKETS) {
    for (int i = 0; i < count - 1; i++) {
      String val = prefs.getString(("p" + String(i + 1)).c_str(), "");
      prefs.putString(("p" + String(i)).c_str(), val);
    }
    count--;
  }
  prefs.putString(("p" + String(count)).c_str(), json);
  prefs.putInt("count", count + 1);
  prefs.end();
  Serial.println("[QUEUE] Pacchetto salvato (" + String(count + 1) + " in attesa).");
}

void svuotaCoda() {
  prefs.begin("pkt_queue", false);
  int count = prefs.getInt("count", 0);
  if (count == 0) { prefs.end(); return; }
  Serial.println("[QUEUE] " + String(count) + " pacchetti in coda. Ritrasmissione...");
  int inviati = 0;
  for (int i = 0; i < count; i++) {
    String json = prefs.getString(("p" + String(i)).c_str(), "");
    if (json.length() == 0) { inviati++; continue; }
    if (inviaJsonHTTP(json)) { inviati++; delay(300); }
    else { break; }
  }
  int remaining = count - inviati;
  for (int i = 0; i < remaining; i++) {
    String val = prefs.getString(("p" + String(i + inviati)).c_str(), "");
    prefs.putString(("p" + String(i)).c_str(), val);
  }
  for (int i = remaining; i < count; i++) prefs.remove(("p" + String(i)).c_str());
  prefs.putInt("count", remaining);
  prefs.end();
  Serial.println("[QUEUE] Rimasti in coda: " + String(remaining));
}

// ═══════════════════════════════════════════════
//  SEZIONE 6 — INVIO DATI PRINCIPALE
// ═══════════════════════════════════════════════
void inviaDati(float l_lat, float l_lon, const BatInfo& bat, const String& timestamp, const StepData& step, bool isSleeping, bool gpsValid) {

  sendAT("AT+HTTPTERM"); // Chiude sessioni precedenti
  delay(200);
  sendAT("AT+HTTPINIT"); // Inizializza nuova sessione

  String json = "{";
  json += "\"board_id\":\"" + String(global_board_id) + "\",";
  json += "\"timestamp\":\"" + timestamp + "\",";
  json += "\"lat\":" + String(l_lat, 6) + ",";
  json += "\"lon\":" + String(l_lon, 6) + ",";
  
  float b_v = (bat.voltage > 0.1f) ? bat.voltage : 0.0;
  int b_p = (bat.voltage > 0.1f) ? bat.percent : 0;

  json += "\"battery\":" + String(b_v, 2) + ",";
  json += "\"battery_percent\":" + String(b_p) + ",";
  json += "\"charging\":" + String(bat.charging ? "true" : "false") + ",";
  json += "\"steps\":" + String(step.lastSession) + ",";
  json += "\"sleep\":" + String(isSleeping ? "true" : "false") + ",";
  json += "\"gps_valid\":" + String(gpsValid ? "true" : "false") + ",";
  json += "\"gps_fail_count\":" + String(gpsFailCount) + ",";
  json += "\"net_fail_count\":" + String(previousNetFails);
  json += "}";

  Serial.println("[JSON DEBUG] " + json);
  
  if (!inviaJsonHTTP(json)) {
    Serial.println("[HTTP] Invio fallito.");
    salvaInCoda(json);
  }
}

// ═══════════════════════════════════════════════
//  POWER MANAGEMENT
// ═══════════════════════════════════════════════
void enterDeepSleep() {
  Serial.println("\n[POWER] Deep Sleep...");
  sendAT("AT+CGNSSPWR=0");
  sendAT("AT+CPOWD=1");
  delay(1000);
  digitalWrite(PIN_EN, LOW);
  digitalWrite(BAT_ADC_EN, LOW);
  uint16_t status;
  do { accelerometer.getInterruptStatus(&status); delay(50); }
  while (digitalRead(WAKEUP_PIN) == HIGH);
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

  // ── Attendi connessione Serial CDC (USB virtuale ESP32-S3) ────────────────
  // Con CDCOnBoot=cdc il Serial non è disponibile finché il PC non apre
  // la porta. Aspettiamo max 3s: se il monitor è già aperto lo vediamo
  // subito, se non c'è USB saltiamo e continuiamo normalmente.
  {
    unsigned long t0 = millis();
    while (!Serial && (millis() - t0 < 3000)) delay(10);
    if (Serial) delay(300); // lascia stabilizzare il buffer USB
  }

  bootCount++;
  Serial.println("\n\n=== BOOT #" + String(bootCount) + " ===");

  if (!initAccelerometer()) { Serial.println("[ERR] Accelerometro non trovato!"); while(1); }

  pinMode(PIN_EN, OUTPUT); digitalWrite(PIN_EN, HIGH);
  analogReadResolution(12); analogSetAttenuation(ADC_11db);

  // ── Modem power-on ────────────────────────────────────────────────────────
  pinMode(MODEM_PWRKEY, OUTPUT);
  digitalWrite(MODEM_PWRKEY, LOW);  delay(1000);
  digitalWrite(MODEM_PWRKEY, HIGH); delay(3000);
  modem.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);
  delay(2000);

  // ── IMEI ──────────────────────────────────────────────────────────────────
  if (strcmp(global_board_id, "UNKNOWN") == 0) {
    String imei = getModemIMEI();
    if (imei != "UNKNOWN_IMEI") imei.toCharArray(global_board_id, 16);
  }
  Serial.println("[SYS] Board ID (IMEI): " + String(global_board_id));

  // ── Rete ──────────────────────────────────────────────────────────────────
  isNetworkConnected = connectToNetworkFast();
  if (!isNetworkConnected) {
    netFailCount++;
    Serial.println("[SYS] Rete non disponibile (fail #" + String(netFailCount) + "). Deep Sleep.");
    enterDeepSleep();
    return;
  }
  previousNetFails = netFailCount;
  netFailCount = 0;

  // ── Auth JWT ───────────────────────────────────────────────────────────────
  if (!ensureValidToken()) {
    // Senza token non possiamo inviare nulla, ma potremmo raccogliere dati
    // e salvarli in coda sperando nel rinnovo al prossimo boot.
    // Per ora: tentiamo comunque il loop (inviaJsonHTTP gestirà il 401).
    Serial.println("[AUTH] Avviso: nessun token valido. L'invio potrebbe fallire.");
  }

  // ── Svuota coda pacchetti in attesa ──────────────────────────────────────
  svuotaCoda();

  // ── GPS ───────────────────────────────────────────────────────────────────
  sendAT("AT+CGNSSPWR=0", 500);
  sendAT("AT+CVAUXV=3000", 500); sendAT("AT+CVAUXS=1", 500);
  sendAT("AT+CGNSCFG=11", 500);
  sendAT("AT+CGDRT=4,1", 500);   sendAT("AT+CGSETV=4,1", 500);
  sendAT("AT+CGNSSPWR=1", 1000);
  if (hasGpsFix) iniettaGps();

  Serial.println("[GPS] Attesa fix iniziale (max " + String(GPS_TIMEOUT / 1000) + "s)...");
  unsigned long gpsSetupStart = millis();
  GpsData initialGps;
  while (!initialGps.valid && (millis() - gpsSetupStart < GPS_TIMEOUT)) {
    initialGps = getGpsData();
    if (!initialGps.valid) delay(GPS_POLL_INTERVAL);
  }
  if (initialGps.valid) {
    lastLat = initialGps.lat; lastLon = initialGps.lon; hasGpsFix = true; gpsFailCount = 0;
    salvaDataOraGps();
    Serial.print("[GPS] Fix OK → "); Serial.print(lastLat, 6); Serial.print(", "); Serial.println(lastLon, 6);
  }

  lastActivityTime = millis();
  lastGpsPollTime  = millis();
  Serial.println("=== SISTEMA PRONTO === (boot #" + String(bootCount) + ")");
}

// ═══════════════════════════════════════════════
//  LOOP
// ═══════════════════════════════════════════════
void loop() {
  static uint32_t lastSessionStepsCount = 0;
  static GpsData  currentGps;

  if (millis() - lastGpsPollTime >= GPS_POLL_INTERVAL) {
    lastGpsPollTime = millis();
    GpsData polled = getGpsData();
    if (polled.valid) {
      currentGps = polled;
      if (abs(polled.lat - lastLat) > 0.00001f || abs(polled.lon - lastLon) > 0.00001f || !hasGpsFix) {
        lastLat = polled.lat; lastLon = polled.lon; hasGpsFix = true; gpsFailCount = 0;
        salvaDataOraGps();
      }
    }
  }

  StepData step = readStepData(lastSessionStepsCount);
  BatInfo  bat  = leggiBatteria();

  if (step.hasNewSteps) {
    lastActivityTime = millis();
    step.lastSession = step.session - lastSessionStepsCount;
    lastSessionStepsCount = step.session;
    String ts = getTimestamp();
    if (currentGps.valid) {
      inviaDati(currentGps.lat, currentGps.lon, bat, ts, step, false, true);
    } else if (hasGpsFix) {
      gpsFailCount++;
      inviaDati(lastLat, lastLon, bat, ts, step, false, false);
    } else {
      gpsFailCount++;
      inviaDati(0.0f, 0.0f, bat, ts, step, false, false);
    }
  }
  else if (millis() - lastActivityTime > SLEEP_TIMEOUT) {
    Serial.println("[SYS] Inattività. Invio sleep.");
    String ts = getTimestamp();
    float sLat = currentGps.valid ? currentGps.lat : lastLat;
    float sLon = currentGps.valid ? currentGps.lon : lastLon;
    bool  sGpsValid = currentGps.valid || hasGpsFix;
    inviaDati(sLat, sLon, bat, ts, step, true, sGpsValid);
    delay(2000);
    enterDeepSleep();
  }

  delay(LOOP_INTERVAL);
}
