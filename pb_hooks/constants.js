// ═══════════════════════════════════════════════════════════════
// File: constants.js
// Costanti condivise tra tutti i moduli
// ═══════════════════════════════════════════════════════════════
//
// TABELLA STATI
// │ Attivo  │ Sleep │ Alarm │ Descrizione                     │
// ├─────────┼───────┼───────┼─────────────────────────────────┤
// │   i     │   d   │  any  │ Inside — dentro la geofence     │
// │   v     │   a   │ false │ Trip   — in viaggio, alarm off  │
// │   r     │   q   │ true  │ Trip   — in viaggio, alarm on   │
// │   s     │   p   │ true  │ Search — fuori zona, alarm on   │
// │   w     │   z   │ false │ Walk   — fuori zona, alarm off  │
//
// REGOLE TRANSIZIONE TRIP:
//   trip=true  && alarm=false -> "v"
//   trip=true  && alarm=true  -> "r"
//   trip=false && era "v"/"r" && steps==0  -> mantieni "v"/"r"
//   trip=false && era "v"/"r" && steps>0   -> ricalcola geofence
//
// ═══════════════════════════════════════════════════════════════

/**
 * Timeout watchdog in millisecondi.
 * Se un'activity attiva non riceve pacchetti per questo intervallo
 * viene chiusa automaticamente con anomaly=true.
 */
const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000; // 10 minuti

/** URL bridge notifiche FCM — endpoint singolo (legacy) */
const BRIDGE_URL = "http://127.0.0.1:3000/send";

/** URL bridge notifiche FCM — endpoint batch (ottimizzato) */
const BRIDGE_URL_BATCH = "http://127.0.0.1:3000/send-batch";

/**
 * Mappa sleep -> attivo.
 * Usata per:
 *  - risveglio: convertire lo stato sleep nel corrispondente attivo
 *  - normalizzazione in computeStatus: capire da dove viene l'animale
 */
const SLEEP_TO_ACTIVE = {
    d: "i", // dormiva dentro   -> inside
    a: "v", // dormiva in trip  -> trip (alarm off)
    q: "r", // dormiva in trip  -> trip (alarm on)
    p: "s", // dormiva in cerca -> search
    z: "w", // dormiva fuori    -> walk
};

/**
 * Mappa attivo -> sleep.
 * Usata quando arriva sleep=true: determina lo stato sleep da assegnare
 * in base allo stato attivo corrente.
 */
const ACTIVE_TO_SLEEP = {
    i: "d", // inside     -> dormiva dentro
    v: "a", // trip (off) -> dormiva in trip (off)
    r: "q", // trip (on)  -> dormiva in trip (on)
    s: "p", // search     -> dormiva in cerca
    w: "z", // walk       -> dormiva fuori
};

/**
 * Set di tutti gli stati attivi validi.
 * Usato per validazione e controlli di appartenenza.
 */
const ACTIVE_STATES = new Set(["i", "v", "r", "s", "w"]);

/**
 * Set di tutti gli stati sleep validi.
 * Usato in risveglio e mezzanotte per identificare record dormenti.
 */
const SLEEP_STATES = new Set(["d", "a", "q", "p", "z"]);

/**
 * Set degli stati che richiedono una geofence attiva per essere validi.
 * Se non c'è geofence e lo stato corrente è uno di questi -> fallback a "w".
 */
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