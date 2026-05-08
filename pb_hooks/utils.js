// ═══════════════════════════════════════════════════════════════
// File: utils.js
// Funzioni helper: board, batteria, posizioni, notifiche, geofence, computeStatus
// ═══════════════════════════════════════════════════════════════
//
// MACCHINA A STATI (priorità: trip → inside → alarm):
//
//  1. trip=true && steps==0              → "v"
//  2. trip=false && era "v":
//       steps==0 (ancora fermo)          → rimane "v"
//       steps>0  (ha ripreso)            → ricalcola geofence → i/s/w
//  3. inside=true                        → "i"
//  4. inside=false && alarm=true         → "s"
//  5. inside=false && alarm=false        → "w"
//
// NOTE:
//  - getBoardRecord va chiamata UNA SOLA VOLTA per pacchetto
//  - getItalyTime() calcola l'offset Italia dinamicamente (ora legale/solare)
//  - saveBattery: salva battery_data E controlla notifiche
//  - createNewActivity: crea e salva una nuova activity, ritorna il record
//  - notifyBoardUsers: usa /send-batch → 1 chiamata HTTP per tutti i token
//
// ═══════════════════════════════════════════════════════════════

const {
    BRIDGE_URL_BATCH,
    SLEEP_TO_ACTIVE,
    ACTIVE_TO_SLEEP,
    ACTIVE_STATES,
    SLEEP_STATES,
    GEOFENCE_STATES,
} = require(`${__hooks}/constants.js`);

// ─────────────────────────────────────────────────────────────────────────────
// ORA ITALIANA DINAMICA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Restituisce il timestamp corrente in ora italiana (ms).
 * Calcola automaticamente l'offset UTC+1 (ora solare) o UTC+2 (ora legale).
 * L'ora legale italiana inizia l'ultima domenica di marzo e finisce
 * l'ultima domenica di ottobre, allineata alle regole europee.
 */
function getItalyTime() {
    const now  = new Date();
    const year = now.getUTCFullYear();

    const lastSundayMarch = new Date(Date.UTC(year, 2, 31));
    lastSundayMarch.setUTCDate(31 - lastSundayMarch.getUTCDay());

    const lastSundayOctober = new Date(Date.UTC(year, 9, 31));
    lastSundayOctober.setUTCDate(31 - lastSundayOctober.getUTCDay());

    const isDST    = now >= lastSundayMarch && now < lastSundayOctober;
    const offsetMs = isDST ? 2 * 60 * 60 * 1000 : 1 * 60 * 60 * 1000;

    return now.getTime() + offsetMs;
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS BOARD
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Restituisce il record board cercando prima per campo "board" (IMEI),
 * poi come fallback per id record PocketBase.
 * Chiamare UNA SOLA VOLTA per pacchetto e passare il risultato ai metodi successivi.
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
// BATTERIA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Salva il record battery_data e controlla se inviare notifica.
 *
 * @param {object}  app
 * @param {string}  boardId
 * @param {string}  timestamp
 * @param {number}  battery         - voltaggio
 * @param {number}  batteryPercent  - percentuale
 * @param {boolean} isCharging
 * @param {object}  board           - record board già letto (può essere null)
 */
function saveBattery(app, boardId, timestamp, battery, batteryPercent, isCharging, board) {
    // 1. Salva sempre il record battery_data
    try {
        const colB = app.findCollectionByNameOrId("battery_data");
        const recB = new Record(colB);
        recB.set("board_id",        boardId);
        recB.set("timestamp",       timestamp);
        recB.set("battery",         battery);
        recB.set("battery_percent", batteryPercent);
        recB.set("charging",        isCharging);
        app.save(recB);
    } catch (err) {
        console.log(`[BATTERY SAVE] board=${boardId} errore: ` + err);
    }

    // 2. Controlla e invia notifica se lo stato è cambiato.
    // Se board non è passata, skip delle notifiche.
    if (!board) return;

    try {
        const lastStatus = board.getString("battery_status") || "ok";
        let newStatus    = lastStatus;
        let shouldNotify = false;

        if (isCharging && lastStatus !== "carica") {
            newStatus = "carica"; shouldNotify = true;
        } else if (!isCharging && batteryPercent <= 10) {
            if (lastStatus !== "critical") { newStatus = "critical"; shouldNotify = true; }
        } else if (!isCharging && batteryPercent <= 20) {
            if (lastStatus === "ok" || lastStatus === "carica" || lastStatus === "critical") {
                newStatus = "low"; shouldNotify = true;
            }
        } else if (batteryPercent > 20 && !isCharging) {
            newStatus = "ok";
        }

        if (newStatus !== lastStatus) {
            board.set("battery_status", newStatus);
            app.save(board);

            if (shouldNotify) {
                const notificationMap = {
                    "carica":   { title: "⚡ Batteria in carica", body: "Batteria in caricamento" },
                    "critical": { title: "🪫 Batteria critica",   body: `Livello critico: ${batteryPercent}% — caricare subito` },
                    "low":      { title: "🔋 Batteria bassa",     body: `Livello basso: ${batteryPercent}%` },
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
// ACTIVITY
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Crea e salva una nuova activity con is_active=true.
 *
 * @param {object} app
 * @param {string} boardRecordId  - id PocketBase della board (non IMEI)
 * @param {string} timestamp
 * @param {string} status         - stato attivo (i, v, s, w)
 * @param {number} steps
 * @returns {object}              - il record activity creato
 */
function createNewActivity(app, boardRecordId, timestamp, status, steps) {
    const col = app.findCollectionByNameOrId("activities");
    const rec = new Record(col);
    rec.set("board_id",    boardRecordId);
    rec.set("start_time",  timestamp);
    rec.set("end_time",    timestamp);
    rec.set("is_active",   true);
    rec.set("status",      status);
    rec.set("total_steps", steps);
    app.save(rec);
    console.log(`[ACTIVITY] Creata: ${rec.id} | status: ${status}`);
    return rec;
}

/**
 * Salva una posizione GPS agganciandola ad una activity.
 *
 * @param {object}      app
 * @param {string}      boardRecordId
 * @param {string}      timestamp
 * @param {number}      lat
 * @param {number}      lon
 * @param {string|null} activityId
 */
function savePosition(app, boardRecordId, timestamp, lat, lon, activityId) {
    try {
        const colP = app.findCollectionByNameOrId("positions");
        const recP = new Record(colP);
        recP.set("board_id",  boardRecordId);
        recP.set("timestamp", timestamp);
        recP.set("lat",       lat);
        recP.set("lon",       lon);
        if (activityId) recP.set("activity", activityId);
        app.save(recP);
        console.log(`[POSITION] Salvata per activity: ${activityId ?? "nessuna"}`);
    } catch (err) {
        console.log("[POSITION ERRORE] " + err);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICHE FCM
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Rimuove un token FCM invalido dal record utente.
 */
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
 *
 * Ottimizzazioni:
 *  - 1 query DB per tutti gli utenti invece di N query separate
 *  - 1 chiamata HTTP batch al bridge invece di N chiamate singole
 *  - Il bridge parallelizza internamente con Promise.all
 *
 * @param {object} app
 * @param {object} board    - record board già letto
 * @param {string} boardId
 * @param {string} title
 * @param {string} body
 */
function notifyBoardUsers(app, board, boardId, title, body) {
    try {
        const userIds = getBoardUsers(board);
        if (userIds.length === 0) {
            console.log(`[NOTIFY] Nessun utente per board=${boardId}`);
            return;
        }

        // ── 1 query per tutti gli utenti ─────────────────────────────────────
        const users = app.findRecordsByFilter(
            "users",
            `id in (${userIds.map(id => `"${id}"`).join(",")})`,
            "", 0, 0
        );

        if (!users || users.length === 0) {
            console.log(`[NOTIFY] Nessun record utente trovato per board=${boardId}`);
            return;
        }

        // Raccoglie tutti i token e mappa token → userId per cleanup
        const allTokens    = [];
        const tokenUserMap = {}; // token → userId

        users.forEach(user => {
            try {
                const tokenString = user.getString("tokenFCM");
                if (!tokenString) return;
                const tokens = JSON.parse(tokenString);
                if (!Array.isArray(tokens) || tokens.length === 0) return;
                tokens.forEach(token => {
                    allTokens.push(token);
                    tokenUserMap[token] = user.id;
                });
            } catch (parseErr) {
                console.log(`[NOTIFY] Errore parsing token utente ${user.id}: ` + parseErr);
            }
        });

        if (allTokens.length === 0) {
            console.log(`[NOTIFY] Nessun token FCM valido per board=${boardId}`);
            return;
        }

        // ── 1 chiamata HTTP batch al bridge ───────────────────────────────────
        const response = $http.send({
            url:     BRIDGE_URL_BATCH,
            method:  "POST",
            headers: { "Content-Type": "application/json" },
            body:    JSON.stringify({
                tokens: allTokens,
                title:  title,
                body:   `Board ${boardId}: ${body}`
            })
        });

        console.log(`[NOTIFY] Batch inviato per board=${boardId} | token=${allTokens.length} | status=${response.statusCode}`);

        // ── Cleanup token invalidi segnalati dal bridge ───────────────────────
        if (response.statusCode === 200) {
            try {
                const data         = JSON.parse(response.body);
                const invalidList  = data.invalidTokens || [];

                if (invalidList.length > 0) {
                    console.log(`[NOTIFY] Token invalidi da rimuovere: ${invalidList.length}`);
                    invalidList.forEach(token => {
                        const userId = tokenUserMap[token];
                        if (userId) removeToken(app, userId, token);
                    });
                }
            } catch (parseErr) {
                console.log(`[NOTIFY] Errore parsing risposta bridge: ` + parseErr);
            }
        } else {
            console.log(`[NOTIFY] Bridge ha risposto con status ${response.statusCode}`);
        }

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
                let raw      = typeof fence.get === "function" ? fence.get("vertices") : fence.vertices;
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
 * @param {object}       app
 * @param {object|null}  board       - record board già letto
 * @param {string}       boardId
 * @param {number}       lat
 * @param {number}       lon
 * @param {boolean}      isTrip      - flag trip confermato (solo 2° pacchetto)
 * @param {number}       steps
 * @param {string|null}  prevStatus  - stato attivo o sleep (normalizzato internamente)
 * @returns {string}                 - nuovo stato attivo
 */
function computeStatus(app, board, boardId, lat, lon, isTrip, steps, prevStatus) {

    // Normalizza prevStatus sleep → attivo: "a"→"v", "d"→"i", "p"→"s", "z"→"w"
    let effectivePrev = prevStatus;
    if (prevStatus && SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
    }

    // ── 1. TRIP ──────────────────────────────────────────────────────────────
    // steps==0 evita falsi positivi quando l'animale è già in movimento
    if (isTrip && steps === 0) {
        if (effectivePrev !== "v") {
            notifyBoardUsers(app, board, boardId, "🚗 Animale in viaggio", "L'animale è su un veicolo");
            console.log(`[TRIP] board=${boardId} ingresso in viaggio (era: ${effectivePrev})`);
        }
        return "v";
    }

    // ── 2. ERA IN VIAGGIO (trip=false) ───────────────────────────────────────
    // steps==0 mantiene "v" anche dopo trip-sleep
    if (effectivePrev === "v") {
        if (steps === 0) {
            console.log(`[TRIP] board=${boardId} trip=false ma steps==0, manteniamo "v"`);
            return "v";
        }
        console.log(`[TRIP] board=${boardId} uscita viaggio con steps=${steps}, ricalcolo geofence`);
    }

    // ── 3. INSIDE / OUTSIDE ──────────────────────────────────────────────────
    const hasCoords = !(lat === 0.0 && lon === 0.0);
    if (!hasCoords) return effectivePrev ?? "w";

    const geoResult = getGeofenceStatus(app, boardId, lat, lon);

    if (geoResult === "no_geofence") {
        // GEOFENCE_STATES = Set["i", "s"] — stati che richiedono geofence attiva
        if (effectivePrev && GEOFENCE_STATES.has(effectivePrev)) {
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
// EXPORTS
// ─────────────────────────────────────────────────────────────────────────────

module.exports = {
    SLEEP_TO_ACTIVE,
    ACTIVE_TO_SLEEP,
    ACTIVE_STATES,
    SLEEP_STATES,
    GEOFENCE_STATES,
    getItalyTime,
    getBoardRecord,
    getBoardUsers,
    getBoardAlarm,
    saveBattery,
    createNewActivity,
    savePosition,
    salvaEvento,
    notifyBoardUsers,
    pointInPolygon,
    getGeofenceStatus,
    computeStatus,
};
