// ═══════════════════════════════════════════════════════════════
// File: utils.js
// ═══════════════════════════════════════════════════════════════
//
// STATI ATTIVI  : i (inside), v (trip/viaggio), s (search), w (walk)
// STATI SLEEP   : d (←i), a (←v), p (←s), z (←w)
//
// MACCHINA A STATI (priorità: trip → inside → alarm):
//
//  1. trip=true                      → "v"  (sempre, ignora geofence)
//  2. trip=false && era "v" o "a":
//       steps==0 (ancora fermo)      → rimane "v"
//       steps>0  (ha ripreso)        → ricalcola geofence → i/s/w
//  3. inside=true                    → "i"
//  4. inside=false && alarm=true     → "s"
//  5. inside=false && alarm=false    → "w"
//
// FIX6: computeStatus, checkBatteryNotify e notifyBoardUsers accettano
// il record board già letto come parametro, evitando query ridondanti.
//
// FIX7: getItalyTime() calcola l'offset Italia dinamicamente (ora legale/solare).
//
// ═══════════════════════════════════════════════════════════════

const SESSION_DEDUP_SEC    = 120;
const WATCHDOG_TIMEOUT_MIN = 10;
const BRIDGE_URL           = "http://127.0.0.1:3000/send";

// Mappe bidirezionali sleep ↔ attivo
const SLEEP_TO_ACTIVE = { d: "i", a: "v", p: "s", z: "w" };
const ACTIVE_TO_SLEEP = { i: "d", v: "a", s: "p", w: "z" };

const ACTIVE_STATES = new Set(["i", "v", "s", "w"]);
const SLEEP_STATES  = new Set(["d", "a", "p", "z"]);

// ─────────────────────────────────────────────────────────────────────────────
// FIX7: ORA ITALIANA DINAMICA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Restituisce il timestamp corrente in ora italiana (ms).
 * Calcola automaticamente l'offset UTC+1 (ora solare) o UTC+2 (ora legale).
 *
 * L'ora legale italiana inizia l'ultima domenica di marzo e finisce
 * l'ultima domenica di ottobre, allineata alle regole europee.
 */
function getItalyTime() {
    const now = new Date();
    const year = now.getUTCFullYear();

    // Ultima domenica di marzo (inizio ora legale)
    const lastSundayMarch = new Date(Date.UTC(year, 2, 31));
    lastSundayMarch.setUTCDate(31 - lastSundayMarch.getUTCDay());

    // Ultima domenica di ottobre (fine ora legale)
    const lastSundayOctober = new Date(Date.UTC(year, 9, 31));
    lastSundayOctober.setUTCDate(31 - lastSundayOctober.getUTCDay());

    const isDST = now >= lastSundayMarch && now < lastSundayOctober;
    const offsetMs = isDST ? 2 * 60 * 60 * 1000 : 1 * 60 * 60 * 1000;

    return now.getTime() + offsetMs;
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS BOARD
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Restituisce il record board cercando prima per campo "board" (IMEI),
 * poi come fallback per id record PocketBase.
 * Chiamare questa funzione UNA SOLA VOLTA per pacchetto e passare
 * il risultato ai metodi successivi (FIX6).
 */
function getBoardRecord(app, boardId) {
    try {
        const res = app.findRecordsByFilter("boards", "board = {:id}", "", 1, 0, { id: boardId });
        if (res.length > 0) return res[0];
        return app.findRecordById("boards", boardId);
    } catch (err) {
        console.log(`[GET BOARD] board=${boardId} errore: ` + err);
        return null;
    }
}

/**
 * Restituisce l'array di userId collegati alla board.
 * FIX6: accetta il record board già letto per evitare query ridondanti.
 */
function getBoardUsers(board) {
    try {
        if (!board) return [];
        const userIds = board.get("user");
        return Array.isArray(userIds) ? userIds : (userIds ? [userIds] : []);
    } catch (err) {
        console.log("[GET USERS ERRORE] " + err);
        return [];
    }
}

/**
 * Restituisce il valore del campo alarm sulla board.
 * FIX6: accetta il record board già letto per evitare query ridondanti.
 */
function getBoardAlarm(board) {
    try {
        return board ? board.getBool("alarm") : false;
    } catch (err) {
        console.log(`[GET ALARM] errore: ` + err);
        return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EVENTI
// ─────────────────────────────────────────────────────────────────────────────

function salvaEvento(app, boardId, type, detail) {
    try {
        const col = app.findCollectionByNameOrId("device_events");
        const rec = new Record(col);
        rec.set("board_id",  boardId);
        rec.set("type",      type);
        rec.set("detail",    detail);
        rec.set("timestamp", new Date().toISOString());
        app.save(rec);
    } catch (err) {
        console.log("[EVENTI ERRORE] " + err);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICHE FCM
// ─────────────────────────────────────────────────────────────────────────────

function getTokenUsers(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return null;
        const tokenString = user.getString("tokenFCM");
        if (!tokenString) return null;
        const tokens = JSON.parse(tokenString);
        return Array.isArray(tokens) && tokens.length > 0 ? tokens : null;
    } catch (err) {
        console.log(`[GET TOKEN] utente ${userId} errore: ` + err);
        return null;
    }
}

function removeToken(app, userId, tokenToRemove) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return;
        const tokenString = user.getString("tokenFCM");
        if (!tokenString) return;
        let tokens = JSON.parse(tokenString);
        if (!Array.isArray(tokens)) return;
        const newTokens = tokens.filter(t => t !== tokenToRemove);
        if (newTokens.length !== tokens.length) {
            user.set("tokenFCM", JSON.stringify(newTokens));
            app.save(user);
            console.log(`[CLEANUP] Token rimosso utente ${userId}`);
        }
    } catch (err) {
        console.log("[REMOVE TOKEN ERRORE] " + err);
    }
}

/**
 * Invia una notifica push a TUTTI gli utenti collegati alla board.
 * FIX6: accetta il record board già letto per evitare query ridondanti.
 */
function notifyBoardUsers(app, board, boardId, title, body) {
    try {
        const userIds = getBoardUsers(board);
        if (userIds.length === 0) {
            console.log(`[NOTIFY] Nessun utente per board=${boardId}`);
            return;
        }

        userIds.forEach(userId => {
            try {
                const fcmTokens = getTokenUsers(app, userId);
                if (!fcmTokens || fcmTokens.length === 0) return;

                fcmTokens.forEach(token => {
                    const response = $http.send({
                        url:     BRIDGE_URL,
                        method:  "POST",
                        headers: { "Content-Type": "application/json" },
                        body:    JSON.stringify({
                            token: token,
                            title: title,
                            body:  `Board ${boardId}: ${body}`
                        })
                    });

                    if (response.statusCode === 404 || response.statusCode === 400) {
                        console.log(`[FCM] Token non valido utente ${userId}. Rimozione.`);
                        removeToken(app, userId, token);
                    }
                });
            } catch (uErr) {
                console.log(`[NOTIFY] Errore utente ${userId}: ` + uErr);
            }
        });
    } catch (err) {
        console.log("[NOTIFY ERRORE] " + err);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GEOFENCE
// ─────────────────────────────────────────────────────────────────────────────

function pointInPolygon(lat, lon, vertices) {
    let inside = false;
    const n = vertices.length;
    for (let i = 0, j = n - 1; i < n; j = i++) {
        const latI = vertices[i][0], lonI = vertices[i][1];
        const latJ = vertices[j][0], lonJ = vertices[j][1];
        const intersect = ((latI > lat) !== (latJ > lat)) &&
            (lon < (lonJ - lonI) * (lat - latI) / (latJ - latI) + lonI);
        if (intersect) inside = !inside;
    }
    return inside;
}

function getGeofenceStatus(app, boardId, lat, lon) {
    try {
        const result = app.findRecordsByFilter(
            "geofences", "board_id = {:id} && is_active = true", "", 0, 0, { id: boardId }
        );

        const geofences = Array.isArray(result) ? result : (result?.items || []);
        if (geofences.length === 0) return "no_geofence";

        const numLat = parseFloat(lat);
        const numLon = parseFloat(lon);

        for (const fence of geofences) {
            try {
                let raw = typeof fence.get === "function" ? fence.get("vertices") : fence.vertices;
                let vertices = raw;

                if (typeof vertices === "string") {
                    vertices = JSON.parse(vertices);
                } else if (typeof vertices === "object" && vertices !== null && !Array.isArray(vertices[0])) {
                    vertices = JSON.parse(vertices.toString());
                }

                if (Array.isArray(vertices) && vertices.length >= 3 && vertices.length < 100) {
                    if (pointInPolygon(numLat, numLon, vertices)) return "inside";
                }
            } catch (e) {
                console.log("[GEOFENCE] Errore processamento fence: " + e);
            }
        }
        return "outside";
    } catch (err) {
        console.log("[GEOFENCE ERRORE GENERALE] " + err);
        return "outside";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MACCHINA A STATI PRINCIPALE
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Calcola il nuovo status attivo secondo la priorità: trip → inside → alarm.
 *
 * FIX6: accetta il record board già letto per evitare query ridondanti.
 *
 * @param {object}       app
 * @param {object|null}  board       - record board già letto (FIX6)
 * @param {string}       boardId
 * @param {number}       lat
 * @param {number}       lon
 * @param {boolean}      isTrip
 * @param {number}       steps
 * @param {string|null}  prevStatus  - attivo o sleep, normalizzato internamente
 * @returns {string}
 */
function computeStatus(app, board, boardId, lat, lon, isTrip, steps, prevStatus) {

    // Normalizza prevStatus sleep → attivo: "a"→"v", "d"→"i", "p"→"s", "z"→"w"
    let effectivePrev = prevStatus;
    if (prevStatus && SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
    }

    // ── 1. TRIP ──────────────────────────────────────────────────────────────
    // Chiamato solo per trip=true confermato (secondo pacchetto) grazie al hold.
    if (isTrip) {
        if (effectivePrev !== "v") {
            notifyBoardUsers(app, board, boardId, "🚗 Animale in viaggio", "L'animale è su un veicolo");
            console.log(`[TRIP] board=${boardId} ingresso in viaggio (era: ${effectivePrev})`);
        }
        return "v";
    }

    // ── 2. ERA IN VIAGGIO (trip=false) ───────────────────────────────────────
    // "a" normalizzato a "v": steps==0 mantiene "v" anche dopo trip-sleep.
    if (effectivePrev === "v") {
        if (steps === 0) {
            console.log(`[TRIP] board=${boardId} trip=false ma steps==0, manteniamo "v"`);
            return "v";
        }
        console.log(`[TRIP] board=${boardId} uscita viaggio con steps=${steps}, ricalcolo geofence`);
    }

    // ── 3. INSIDE / OUTSIDE ──────────────────────────────────────────────────
    const hasCoords = !(lat === 0.0 && lon === 0.0);
    if (!hasCoords) {
        return effectivePrev ?? "w";
    }

    const geoResult = getGeofenceStatus(app, boardId, lat, lon);

    if (geoResult === "no_geofence") {
        const geofenceStates = new Set(["i", "s"]);
        if (effectivePrev && geofenceStates.has(effectivePrev)) {
            console.log(`[GEOFENCE] board=${boardId} nessuna geofence, stato "${effectivePrev}" non valido → "w"`);
            notifyBoardUsers(app, board, boardId, "Nessuna zona configurata", "Le zone di monitoraggio sono state disattivate");
            return "w";
        }
        if (effectivePrev === "v") {
            notifyBoardUsers(app, board, boardId, "🐾 Cane sceso dal veicolo in passeggiata", "L'animale è sceso dal veicolo");
            return "w";
        }
        console.log(`[GEOFENCE] board=${boardId} nessuna geofence, manteniamo "${effectivePrev ?? "w"}"`);
        return effectivePrev ?? "w";
    }

    const inside   = geoResult === "inside";
    // FIX6: usa il record board già letto
    const hasAlarm = getBoardAlarm(board);

    // ── Inside ───────────────────────────────────────────────────────────────
    if (inside) {
        if (effectivePrev !== "i") {
            const msgMap = {
                "s":  ["✅ Animale rientrato",       "L'animale è rientrato nella zona monitorata"],
                "w":  ["🏠 Animale rientrato",       "L'animale è tornato dalla passeggiata"],
                "v":  ["🏠 Arrivato a destinazione", "L'animale è sceso dal veicolo nella zona sicura"],
                null: ["🏠 Animale in zona",         "L'animale si trova nella zona sicura"],
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🏠 Animale in zona", "L'animale si trova nella zona sicura"];
            notifyBoardUsers(app, board, boardId, title, body);
        }
        return "i";
    }

    // ── Outside ──────────────────────────────────────────────────────────────
    if (hasAlarm) {
        if (effectivePrev !== "s") {
            const msgMap = {
                "i":  ["🚨 Uscita dalla zona",         "L'animale è uscito dalla zona monitorata"],
                "w":  ["🚨 Ricerca attivata",          "Allarme attivato mentre l'animale era in passeggiata"],
                "v":  ["🚨 Cane scappato dal veicolo", "Allarme! L'animale è fuggito scendendo dal veicolo"],
                null: ["🚨 Animale fuori zona",        "L'animale è fuori dalla zona monitorata"],
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🚨 Animale fuori zona", "L'animale è fuori dalla zona monitorata"];
            notifyBoardUsers(app, board, boardId, title, body);
        }
        return "s";
    } else {
        if (effectivePrev !== "w") {
            const msgMap = {
                "i":  ["🐾 Animale in passeggiata",                "L'animale è uscito per una passeggiata"],
                "s":  ["🔍 Animale trovato",                       "L'animale è stato trovato"],
                "v":  ["🐾 Cane sceso dal veicolo in passeggiata", "L'animale ha iniziato una passeggiata"],
                null: ["🐾 Animale rilevato",                      "L'animale è fuori dalla zona monitorata"],
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🐾 Animale fuori zona", "L'animale si trova fuori dalla zona monitorata"];
            notifyBoardUsers(app, board, boardId, title, body);
        }
        return "w";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BATTERIA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Controlla il livello batteria e invia notifica se lo stato è cambiato.
 * FIX6: accetta il record board già letto per evitare query ridondanti.
 */
function checkBatteryNotify(app, board, batteryPercent, isCharging) {
    try {
        if (!board) return;

        const lastStatus = board.getString("battery_status") || "ok";
        let newStatus    = lastStatus;
        let shouldNotify = false;

        if (isCharging && lastStatus !== "carica") {
            newStatus = "carica"; shouldNotify = true;
        } else if (batteryPercent <= 10) {
            if (lastStatus !== "critical") { newStatus = "critical"; shouldNotify = true; }
        } else if (batteryPercent <= 20) {
            if (lastStatus === "ok" || lastStatus === "carica" || lastStatus === "critical") {
                newStatus = "low"; shouldNotify = true;
            }
        } else if (batteryPercent > 20) {
            newStatus = "ok";
        }

        if (newStatus !== lastStatus) {
            board.set("battery_status", newStatus);
            app.save(board);

            if (shouldNotify) {
                const boardId = board.getString("board");
                const notificationMap = {
                    "carica":   { title: "⚡ Batteria in carica", body: "Batteria in caricamento" },
                    "critical": { title: "🪫 Batteria critica",   body: `Livello critico: ${batteryPercent}% — caricare subito` },
                    "low":      { title: "🔋 Batteria bassa",     body: `Livello basso: ${batteryPercent}%` }
                };
                const content = notificationMap[newStatus] || { title: "🔋 Stato Batteria", body: `Livello: ${batteryPercent}%` };
                notifyBoardUsers(app, board, boardId, content.title, content.body);
                console.log(`[BATTERY] board=${boardId} "${lastStatus}" → "${newStatus}" (${batteryPercent}%)`);
            }
        }
    } catch (err) {
        console.log("[BATTERY NOTIFY ERRORE] " + err);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EXPORTS
// ─────────────────────────────────────────────────────────────────────────────

module.exports = {
    SESSION_DEDUP_SEC, WATCHDOG_TIMEOUT_MIN,
    SLEEP_TO_ACTIVE, ACTIVE_TO_SLEEP, ACTIVE_STATES, SLEEP_STATES,
    getItalyTime,
    salvaEvento, notifyBoardUsers, checkBatteryNotify,
    pointInPolygon, getGeofenceStatus, computeStatus,
    getBoardRecord, getBoardUsers, getBoardAlarm,
};