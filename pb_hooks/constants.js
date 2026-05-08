// ═══════════════════════════════════════════════════════════════
// File: constants.js
// Costanti condivise tra tutti i moduli
// ═══════════════════════════════════════════════════════════════
//
// STATI ATTIVI : i (inside), v (trip/viaggio), s (search), w (walk)
// STATI SLEEP  : d (<-i),    a (<-v),           p (<-s),    z (<-w)
//
// ═══════════════════════════════════════════════════════════════

// Timeout watchdog: se un'activity attiva non riceve pacchetti
// per questo intervallo viene chiusa con anomaly=true
const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000; // 10 minuti

// URL bridge notifiche FCM
const BRIDGE_URL       = "http://127.0.0.1:3000/send";
const BRIDGE_URL_BATCH = "http://127.0.0.1:3000/send-batch";

// Mappe bidirezionali sleep ↔ attivo
const SLEEP_TO_ACTIVE = { d: "i", a: "v", p: "s", z: "w" };
const ACTIVE_TO_SLEEP = { i: "d", v: "a", s: "p", w: "z" };

const ACTIVE_STATES   = new Set(["i", "v", "s", "w"]);
const SLEEP_STATES    = new Set(["d", "a", "p", "z"]);

// Stati che richiedono una geofence attiva per essere validi.
// Se non c'è geofence e lo stato corrente è uno di questi -> fallback a "w"
const GEOFENCE_STATES = new Set(["i", "s"]);

module.exports = {
    WATCHDOG_TIMEOUT_MS,
    BRIDGE_URL,
    BRIDGE_URL_BATCH,
    SLEEP_TO_ACTIVE,
    ACTIVE_TO_SLEEP,
    ACTIVE_STATES,
    SLEEP_STATES,
    GEOFENCE_STATES,
};
