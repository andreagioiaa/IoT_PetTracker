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
//  2. trip=false && era "v":
//       steps==0 (ancora fermo)      → rimane "v"  (sleep-in-trip)
//       steps>0  (ha ripreso)        → ricalcola geofence → i/s/w
//  3. inside=true                    → "i"
//  4. inside=false && alarm=true     → "s"
//  5. inside=false && alarm=false    → "w"
//
// TRANSIZIONI NOTIFICATE:
//  qualsiasi cambio di stato attivo → notifica a TUTTI gli utenti board
//
// ═══════════════════════════════════════════════════════════════

const SESSION_DEDUP_SEC    = 120;
const WATCHDOG_TIMEOUT_MIN = 10;
const BRIDGE_URL           = "http://127.0.0.1:3000/send";

// Mappe sleep ↔ attivo
const SLEEP_TO_ACTIVE = { d: "i", a: "v", p: "s", z: "w" };
const ACTIVE_TO_SLEEP = { i: "d", v: "a", s: "p", w: "z" };

const ACTIVE_STATES = new Set(["i", "v", "s", "w"]);
const SLEEP_STATES  = new Set(["d", "a", "p", "z"]);

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS BOARD
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Restituisce il record board cercando prima per campo "board" (IMEI),
 * poi come fallback per id record.
 */
function getBoardRecord(app, boardId) {
    try {
        const res = app.findRecordsByFilter("boards", "board = {:id}", "", 1, 0, { id: boardId });
        if (res.length > 0) return res[0];
        // fallback: boardId è l'id PocketBase del record
        return app.findRecordById("boards", boardId);
    } catch (err) {
        console.log(`[GET BOARD] board=${boardId} errore: ` + err);
        return null;
    }
}

/** Restituisce l'array di userId collegati alla board. */
function getBoardUsers(app, boardId) {
    try {
        const board = getBoardRecord(app, boardId);
        if (!board) return [];
        const userIds = board.get("user");
        return Array.isArray(userIds) ? userIds : (userIds ? [userIds] : []);
    } catch (err) {
        console.log("[GET USERS ERRORE] " + err);
        return [];
    }
}

/** Restituisce il valore del campo alarm sulla board. */
function getBoardAlarm(app, boardId) {
    try {
        const board = getBoardRecord(app, boardId);
        return board ? board.getBool("alarm") : false;
    } catch (err) {
        console.log(`[GET ALARM] board=${boardId} errore: ` + err);
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
 * Nessun filtro per alarm: ogni cambio di stato raggiunge tutti.
 */
function notifyBoardUsers(app, boardId, title, body) {
    try {
        const userIds = getBoardUsers(app, boardId);
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

                    // 404 = UNREGISTERED, 400 = INVALID_ARGUMENT
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

/**
 * Ray Casting: verifica se il punto (lat, lon) è dentro il poligono.
 * Vertici attesi come array di [lat, lon].
 */
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

/**
 * Controlla tutti i geofence attivi della board.
 * @returns "inside" | "outside" | "no_geofence"
 */
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

                // Gestione robusta del formato vertici
                if (typeof vertices === 'string') {
                    vertices = JSON.parse(vertices);
                } else if (typeof vertices === 'object' && vertices !== null && !Array.isArray(vertices[0])) {
                    // Caso in cui sia un oggetto stringabile ma non ancora array di array
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
 * Calcola il nuovo status attivo secondo la priorità:
 *   trip → inside → alarm
 *
 * @param {object}  app
 * @param {string}  boardId
 * @param {number}  lat
 * @param {number}  lon
 * @param {boolean} isTrip       - flag trip del pacchetto
 * @param {number}  steps        - passi del pacchetto
 * @param {string}  prevStatus   - ultimo status salvato (può essere sleep o attivo)
 * @returns {string}             - nuovo status attivo
 */
function computeStatus(app, boardId, lat, lon, isTrip, steps, prevStatus) {

    // Normalizza prevStatus: se sleep → attivo corrispondente
    let effectivePrev = prevStatus;
    if (prevStatus && SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
    }

    // ── 1. TRIP ──────────────────────────────────────────────────────────────
    if (isTrip) {
        if (effectivePrev !== "v") {
            notifyBoardUsers(app, boardId, "🚗 Animale in viaggio", "L'animale è su un veicolo");
            console.log(`[TRIP] board=${boardId} ingresso in viaggio (era: ${effectivePrev})`);
        }
        return "v";
    }

    // ── 2. ERA IN VIAGGIO (trip=false) ───────────────────────────────────────
    if (effectivePrev === "v") {
        if (steps === 0) {
            // Ancora fermo — manteniamo "v" senza ricalcolare geofence
            console.log(`[TRIP] board=${boardId} trip=false ma steps==0, manteniamo "v"`);
            return "v";
        }

        // Ha ripreso a muoversi.
        // NON mandiamo la notifica qui e NON resettiamo effectivePrev.
        // Manteniamo "v" così i blocchi successivi sanno che sta appena scendendo.
        console.log(`[TRIP] board=${boardId} uscita viaggio con steps=${steps}, ricalcolo geofence`);
    }

    // ── 3. INSIDE / OUTSIDE ──────────────────────────────────────────────────
    const hasCoords = !(lat === 0.0 && lon === 0.0);
    if (!hasCoords) {
        // Nessuna coordinata valida: manteniamo stato precedente
        return effectivePrev ?? "w";
    }

    const geoResult = getGeofenceStatus(app, boardId, lat, lon);

    // Nessuna geofence configurata
    if (geoResult === "no_geofence") {
        const geofenceStates = new Set(["i", "s"]);
        if (effectivePrev && geofenceStates.has(effectivePrev)) {
            console.log(`[GEOFENCE] board=${boardId} nessuna geofence, stato "${effectivePrev}" non valido → "w"`);
            notifyBoardUsers(app, boardId, "Nessuna zona configurata", "Le zone di monitoraggio sono state disattivate");
            return "w";
        }
        // Se è appena sceso dal veicolo ma non ci sono geofence, passa in passeggiata
        if (effectivePrev === "v") {
            notifyBoardUsers(app, boardId, "🐾 Cane sceso dal veicolo in passeggiata", "L'animale è sceso dal veicolo");
            return "w";
        }
        
        console.log(`[GEOFENCE] board=${boardId} nessuna geofence, manteniamo "${effectivePrev ?? "w"}"`);
        return effectivePrev ?? "w";
    }

    const inside   = geoResult === "inside";
    const hasAlarm = getBoardAlarm(app, boardId);

    // ── Inside ───────────────────────────────────────────────────────────────
    if (inside) {
        if (effectivePrev !== "i") {
            const msgMap = {
                "s": ["✅ Animale rientrato", "L'animale è rientrato nella zona monitorata"],
                "w": ["🏠 Animale rientrato", "L'animale è tornato dalla passeggiata"],
                "v": ["🏠 Arrivato a destinazione", "L'animale è sceso dal veicolo nella zona sicura"] // Nuovo caso!
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🏠 Animale in zona", "L'animale si trova nella zona sicura"];
            notifyBoardUsers(app, boardId, title, body);
        }
        return "i";
    }

    // ── Outside ──────────────────────────────────────────────────────────────
    if (hasAlarm) {
        if (effectivePrev !== "s") {
            const msgMap = {
                "i": ["🚨 Uscita dalla zona", "L'animale è uscito dalla zona monitorata"],
                "w": ["🚨 Ricerca attivata",  "Allarme attivato mentre l'animale era in passeggiata"],
                "v": ["🚨 Cane Scappato dal veicolo", "Allarme! L'animale è fuggito scendendo dal veicolo"] // Quello che hai richiesto
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🚨 Animale fuori zona", "L'animale è fuori dalla zona monitorata"];
            notifyBoardUsers(app, boardId, title, body);
        }
        return "s";
    } else {
        // Outside, no alarm → walk
        if (effectivePrev !== "w") {
            const msgMap = {
                "i": ["🐾 Animale in passeggiata", "L'animale è uscito per una passeggiata"],
                "s": ["🔍 Animale trovato",            "L'animale è stato trovato"],
                "v": ["🐾 Cane sceso dal veicolo in passeggiata", "L'animale ha iniziato una passeggiata"] // Quello che hai richiesto
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🐾 DIO BOIA", "L'animale è fuori dalla zona sicura"];
            notifyBoardUsers(app, boardId, title, body);
        }
        return "w";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BATTERIA
// ─────────────────────────────────────────────────────────────────────────────

function checkBatteryNotify(app, boardId, batteryPercent, isCharging) {
    try {
        const board = getBoardRecord(app, boardId);
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
                const notificationMap = {
                    "carica":   { title: "⚡ Batteria in carica",  body: "Batteria in caricamento" },
                    "critical": { title: "🪫 Batteria critica",    body: `Livello critico: ${batteryPercent}% — caricare subito` },
                    "low":      { title: "🔋 Batteria bassa",      body: `Livello basso: ${batteryPercent}%` }
                };
                const content = notificationMap[newStatus] || { title: "🔋 Stato Batteria", body: `Livello: ${batteryPercent}%` };
                notifyBoardUsers(app, boardId, content.title, content.body);
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
    salvaEvento, notifyBoardUsers, checkBatteryNotify,
    pointInPolygon, getGeofenceStatus, computeStatus,
    getBoardRecord, getBoardUsers, getBoardAlarm,
};