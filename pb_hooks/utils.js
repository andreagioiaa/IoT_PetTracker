// ═══════════════════════════════════════════════════════════════
// File: utils.js
// ═══════════════════════════════════════════════════════════════

const GPS_FAIL_ALERT_THRESH = 3;
const SESSION_DEDUP_SEC     = 120;
const WATCHDOG_TIMEOUT_MIN  = 10;
const BRIDGE_URL            = "http://127.0.0.1:3000/send";

// Mappe stato sleep ↔ attivo
// Stati attivi:  i (inside), s (search), f (found), w (walk), v (vehicle/trip), n (no geofence)
// Stati sleep:   d (←i), p (←s), h (←f), z (←w), a (←v, trip-sleep), n rimane n
const SLEEP_TO_ACTIVE = { p: "s", d: "i", h: "f", z: "w", a: "v" };
const ACTIVE_TO_SLEEP = { s: "p", i: "d", f: "h", w: "z", n: "n", v: "a" };

const ACTIVE_STATES = new Set(["i", "s", "f", "w", "n", "v"]);
const SLEEP_STATES  = new Set(["p", "d", "h", "z", "a"]);

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

function getBoardUsers(app, boardId) {
    try {
        const boards = app.findRecordsByFilter("boards", "board = {:id}", "", 1, 0, { id: boardId });
        if (boards.length === 0) return [];
        const userIds = boards[0].get("user");
        return userIds ? userIds : [];
    } catch (err) {
        console.log("[GET USERS ERRORE] " + err);
        return [];
    }
}

function getTokenUsers(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return null;

        const tokenString = user.getString("tokenFCM");
        if (!tokenString) return null;

        const tokens = JSON.parse(tokenString);

        if (Array.isArray(tokens) && tokens.length > 0) {
            return tokens;
        }

        return null;
    } catch (err) {
        console.log(`[GET TOKEN] Errore per l'utente ${userId}: ` + err);
        return null;
    }
}

function getUserAlarm(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        return user ? user.getBool("alarm") : false;
    } catch (err) {
        console.log(`[GET ALARM] Utente ${userId} errore: ` + err);
        return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOGICA BATTERIA (Macchina a stati)
// ─────────────────────────────────────────────────────────────────────────────

function checkBatteryNotify(app, boardId, batteryPercent, isCharging) {
    try {
        const boards = app.findRecordsByFilter("boards", "board = {:id}", "", 1, 0, { id: boardId });
        if (boards.length === 0) return;
        const board = boards[0];

        const lastStatus = board.getString("battery_status") || "ok";

        let newStatus    = lastStatus;
        let shouldNotify = false;

        if (isCharging && lastStatus !== "carica") {
            newStatus    = "carica";
            shouldNotify = true;
        } else if (batteryPercent <= 10) {
            if (lastStatus !== "critical") {
                newStatus    = "critical";
                shouldNotify = true;
            }
        } else if (batteryPercent <= 20) {
            if (lastStatus === "ok" || lastStatus === "carica" || lastStatus === "critical") {
                newStatus    = "low";
                shouldNotify = true;
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
                console.log(`[BATTERY] board=${boardId} cambio stato "${lastStatus}" → "${newStatus}". Notifica inviata (${batteryPercent}%)`);
            } else {
                console.log(`[BATTERY] board=${boardId} reset stato a "${newStatus}" (senza notifica)`);
            }
        }

    } catch (err) {
        console.log("[BATTERY NOTIFY ERRORE] " + err);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GEOFENCE
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Verifica se un punto (lat, lon) si trova all'interno di un poligono.
 * Algoritmo: Ray Casting.
 */
function pointInPolygon(lat, lon, vertices) {
    let inside = false;
    const n = vertices.length;

    for (let i = 0, j = n - 1; i < n; j = i++) {
        // Estrazione coordinate: [0] è Latitude, [1] è Longitude
        const latI = vertices[i][0];
        const lonI = vertices[i][1];
        const latJ = vertices[j][0];
        const lonJ = vertices[j][1];

        // Calcolo dell'intersezione tra il raggio orizzontale e il segmento del poligono
        const intersect = ((lonI > lon) !== (lonJ > lon)) &&
            (lat < (latJ - latI) * (lon - lonI) / (lonJ - lonI) + latI);
        
        if (intersect) inside = !inside;
    }
    return inside;
}

/**
 * Recupera i geofence attivi e controlla la posizione del dispositivo.
 */
function getGeofenceStatus(app, boardId, lat, lon) {
    try {
        // Esecuzione query
        const result = app.findRecordsByFilter(
            "geofences", 
            "board_id = {:id} && is_active = true", 
            "", 0, 0, 
            { id: boardId }
        );

        // FIX: Se result è null/undefined, esci subito
        if (!result) return "no_geofence";

        // FIX: Gestione "object is not iterable". 
        // Se il framework restituisce un oggetto contenitore, prendiamo .items
        const geofences = Array.isArray(result) ? result : (result.items || []);

        if (geofences.length === 0) {
            return "no_geofence";
        }

        for (const fence of geofences) {
            let vertices;
            try {
                // Recupero del campo vertices (gestisce sia stringa JSON che oggetto/array)
                const raw = typeof fence.get === "function" ? fence.get("vertices") : fence.vertices;
                vertices = typeof raw === "string" ? JSON.parse(raw) : raw;
            } catch (parseErr) {
                console.log("[GEOFENCE] Errore parsing vertici per record: " + (fence.id || "unknown"));
                continue;
            }

            // Verifica validità array vertici
            if (!Array.isArray(vertices) || vertices.length < 3) continue;

            // Controllo se il punto è nel poligono
            if (pointInPolygon(lat, lon, vertices)) {
                return "inside";
            }
        }

        // Se ha controllato tutti i geofence e non è in nessuno
        return "outside";

    } catch (err) {
        console.log("[GEOFENCE ERRORE] " + err);
        return "outside";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MACCHINA A STATI PRINCIPALE
// ─────────────────────────────────────────────────────────────────────────────

function computeNewStatus(app, boardId, inside, hasAlarm, prevStatus) {
    switch (prevStatus) {
        case "i":
            if (inside) return "i";
            if (hasAlarm) {
                notifyBoardUsers(app, boardId, "🚨 Uscita dalla zona", "L'animale è uscito dalla zona monitorata", true);
                return "s";
            }
            notifyBoardUsers(app, boardId, "🐾 Animale in passeggiata", "L'animale è uscito per una passeggiata", true);
            return "w";

        case "s":
            if (inside) {
                notifyBoardUsers(app, boardId, "✅ Animale rientrato", "L'animale è rientrato autonomamente", true);
                return "i";
            }
            if (!hasAlarm) {
                notifyBoardUsers(app, boardId, "🔍 Animale trovato!", "L'animale è stato trovato fuori zona", true);
                return "f";
            }
            return "s";

        case "f":
            if (inside) {
                notifyBoardUsers(app, boardId, "✅ Animale rientrato", "L'animale è rientrato accompagnato", true);
                return "i";
            }
            return "f";

        case "w":
            if (inside) return "i";
            if (hasAlarm) {
                notifyBoardUsers(app, boardId, "🚨 Ricerca attivata", "Allarme attivato: l'animale è fuori zona", true);
                return "s";
            }
            return "w";

        // "v" viene raggiunto solo come fallback di sicurezza:
        // checkGeofences forza effectivePrev = null all'uscita dal viaggio,
        // quindi normalmente non si arriva qui con prevStatus="v".
        case "v":
            if (inside) return "i";
            if (hasAlarm) {
                notifyBoardUsers(app, boardId, "🚨 Uscita dalla zona (post-viaggio)", "L'animale è fuori zona dopo il viaggio", true);
                return "s";
            }
            return "w";

        default:
            if (inside) return "i";
            if (hasAlarm) {
                notifyBoardUsers(app, boardId, "🚨 Uscita dalla zona", "L'animale è uscito dalla zona monitorata", true);
                return "s";
            }
            return "w";
    }
}

/**
 * checkGeofences
 * @param {object}  app        - PocketBase app
 * @param {string}  boardId    - ID board
 * @param {number}  lat        - Latitudine (0 se non disponibile)
 * @param {number}  lon        - Longitudine (0 se non disponibile)
 * @param {string}  prevStatus - Ultimo status noto (può essere sleep o attivo)
 * @param {boolean} isTrip     - True se il pacchetto ha trip=true
 * @returns {string}           - Nuovo status attivo
 */

function checkGeofences(app, boardId, lat, lon, prevStatus, isTrip = false) {
    const userIds  = getBoardUsers(app, boardId);
    const hasAlarm = userIds.some(uid => getUserAlarm(app, uid));

    // Normalizza prevStatus: se era uno stato sleep, convertilo nel corrispondente attivo
    let effectivePrev = prevStatus;
    if (prevStatus && SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
    }

    // ── GESTIONE TRIP ────────────────────────────────────────────────────────
    if (isTrip) {
        if (effectivePrev !== "v") {
            // Primo pacchetto trip: notifica entrata in viaggio
            notifyBoardUsers(app, boardId, "🚗 Animale in viaggio", "L'animale è su un veicolo");
            console.log(`[TRIP] board=${boardId} entrata in viaggio (era: ${effectivePrev})`);
        }
        return "v";
    }

    // ── USCITA DAL VIAGGIO (trip=false, ma era "v") ──────────────────────────
    if (effectivePrev === "v") {
        notifyBoardUsers(app, boardId, "📍 Animale sceso dal veicolo", "Ricalcolo posizione geofence in corso");
        console.log(`[TRIP] board=${boardId} uscita dal viaggio, ricalcolo geofence`);
        // Forza ricalcolo pulito: tratta come se non ci fosse uno stato precedente
        effectivePrev = null;
    }
    // ────────────────────────────────────────────────────────────────────────

    // Senza coordinate valide: mantieni lo stato precedente (o "n" se ignoto)
    if (!lat && !lon) return effectivePrev ?? "n";

    const geoResult = getGeofenceStatus(app, boardId, lat, lon);

    if (geoResult === "no_geofence") return "n";

    const inside    = geoResult === "inside";
    const newStatus = computeNewStatus(
        app, boardId, inside, hasAlarm,
        effectivePrev === "n" ? null : effectivePrev
    );

    return newStatus;
}

function toSleepStatus(activeStatus) {
    return ACTIVE_TO_SLEEP[activeStatus] ?? "z";
}

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICHE FCM
// ─────────────────────────────────────────────────────────────────────────────

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
            console.log(`[CLEANUP] Token rimosso per l'utente ${userId} (App disinstallata o token scaduto)`);
        }
    } catch (err) {
        console.log("[REMOVE TOKEN ERRORE] " + err);
    }
}

function notifyBoardUsers(app, boardId, title, body, onlyAlarm = false) {
    try {
        const userIds = getBoardUsers(app, boardId);
        if (userIds.length === 0) return;

        userIds.forEach(userId => {
            try {
                if (onlyAlarm && !getUserAlarm(app, userId)) return;

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

                    // 404 = UNREGISTERED (App disinstallata), 400 = INVALID_ARGUMENT (token malformato)
                    if (response.statusCode === 404 || response.statusCode === 400) {
                        console.log(`[FCM] Token non valido per utente ${userId}. Rimozione in corso.`);
                        removeToken(app, userId, token);
                    }
                });

            } catch (uErr) {
                console.log(`Errore invio per l'utente ${userId}: ` + uErr);
            }
        });
    } catch (err) {
        console.log("[NOTIFY ERRORE] " + err);
    }
}

module.exports = {
    GPS_FAIL_ALERT_THRESH, SESSION_DEDUP_SEC, WATCHDOG_TIMEOUT_MIN,
    SLEEP_TO_ACTIVE, ACTIVE_TO_SLEEP, ACTIVE_STATES, SLEEP_STATES,
    salvaEvento, notifyBoardUsers, checkBatteryNotify, pointInPolygon,
    getGeofenceStatus, checkGeofences, computeNewStatus, toSleepStatus
};