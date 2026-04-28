// ═══════════════════════════════════════════════════════════════
// File: utils.js
// ═══════════════════════════════════════════════════════════════

const GPS_FAIL_ALERT_THRESH = 3;
const SESSION_DEDUP_SEC     = 120;
const WATCHDOG_TIMEOUT_MIN  = 10;
const BRIDGE_URL            = "http://127.0.0.1:3000/send";

const SLEEP_TO_ACTIVE = { p: "s", d: "i", h: "f", z: "w" };
const ACTIVE_TO_SLEEP = { s: "p", i: "d", f: "h", w: "z", n: "n" };

const ACTIVE_STATES = new Set(["i", "s", "f", "w", "n"]);
const SLEEP_STATES = new Set(["p", "d", "h", "z"]);

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

/*
function getTokenUsers(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return null;
        const token = user.getString("tokenFCM");
        return token ? token : null;
    } catch (err) {
        console.log(`[GET TOKEN] Utente ${userId} non trovato: ` + err);
        return null;
    }
}
*/

function getTokenUsers(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return null;

        const tokenString = user.getString("tokenFCM");
        if (!tokenString) return null;

        // Converte la stringa JSON in un array JavaScript
        const tokens = JSON.parse(tokenString);

        // Verifica che sia effettivamente un array e che non sia vuoto
        if (Array.isArray(tokens) && tokens.length > 0) {
            return tokens; // Restituisce l'intero array di token
        }

        return null; // Restituisce null se l'array è vuoto o malformato
        
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

// LOGICA BATTERIA OTTIMIZZATA (Macchina a stati)
function checkBatteryNotify(app, boardId, batteryPercent, isCharging) {
    try {
        // 1. Cerchiamo la board.
        const boards = app.findRecordsByFilter("boards", "board = {:id}", "", 1, 0, { id: boardId });
        if (boards.length === 0) return;
        const board = boards[0];

        // 2. Recuperiamo l'ultimo stato noto (se il campo non esiste, di default è 'ok')
        const lastStatus = board.getString("battery_status") || "ok";

        let newStatus = lastStatus;
        let shouldNotify = false;

        if(isCharging && lastStatus != "carica"){
            newStatus = "carica";
            shouldNotify = true;
        }else if (batteryPercent <= 10) {   // 3. Valutazione Soglie
            if (lastStatus !== "critical") {
                newStatus = "critical";
                shouldNotify = true;
            }
        } else if (batteryPercent <= 20) {
            if (lastStatus === "ok" || lastStatus === "carica") {
                newStatus = "low";
                shouldNotify = true;
            }else if (lastStatus === "critical"){
                newStatus = "low";
                shouldNotify = true;
            }
        } else if (batteryPercent > 20) {
            // Reset dello stato solo se ricaricato oltre il 20%
            newStatus = "ok";
        }

        // 4. Salvataggio e Notifica solo se c'è stato un effettivo cambio di stato
        if (newStatus !== lastStatus) {
            board.set("battery_status", newStatus);
            app.save(board);

            if (shouldNotify) {
                // Usiamo un oggetto per mappare titoli e messaggi in modo ordinato
                const notificationMap = {
                    "carica": {
                        title: "⚡ Batteria in carica",
                        body: "Batteria in caricamento"
                    },
                    "critical": {
                        title: "🪫 Batteria critica",
                        body: `Livello critico: ${batteryPercent}% — caricare subito` // 
                    },
                    "low": { // Assumendo che lo stato si chiami "low"
                        title: "🔋 Batteria bassa",
                        body: `Livello basso: ${batteryPercent}%` //
                    }
                };

                // Recuperiamo i dati in base al nuovo stato (con un fallback di sicurezza)
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

function pointInPolygon(lat, lon, vertices) {
    let inside = false;
    const n = vertices.length;
    for (let i = 0, j = n - 1; i < n; j = i++) {
        const [latI, lonI] = vertices[i];
        const [latJ, lonJ] = vertices[j];
        const intersect = ((lonI > lon) !== (lonJ > lon)) &&
            (lat < (latJ - latI) * (lon - lonI) / (lonJ - lonI) + latI);
        if (intersect) inside = !inside;
    }
    return inside;
}

function getGeofenceStatus(app, boardId, lat, lon) {
    try {
        const geofences = app.findRecordsByFilter("geofences", "board_id = {:id} && is_active = true", "", 0, 0, { id: boardId });

        if (!geofences || geofences.length === 0) {
            return "no_geofence";
        }

        for (const fence of geofences) {
            let vertices;
            try {
                const raw = fence.get("vertices");
                vertices = typeof raw === "string" ? JSON.parse(raw) : raw;
            } catch (parseErr) {
                continue;
            }
            if (!Array.isArray(vertices) || vertices.length < 3) continue;
            if (pointInPolygon(lat, lon, vertices)) {
                return "inside";
            }
        }
        return "outside";
    } catch (err) {
        console.log("[GEOFENCE ERRORE] " + err);
        return "outside";
    }
}

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
                notifyBoardUsers(app, boardId, "🚨 Ricerca attivata", "Alarm attivato: l'animale è fuori zona", true);
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

function checkGeofences(app, boardId, lat, lon, prevStatus) {
    const userIds  = getBoardUsers(app, boardId);
    const hasAlarm = userIds.some(uid => getUserAlarm(app, uid));

    let effectivePrev = prevStatus;
    if (SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
    }

    if (!lat && !lon) return effectivePrev ?? "n";

    const geoResult = getGeofenceStatus(app, boardId, lat, lon);

    if (geoResult === "no_geofence") return "n";

    const inside    = geoResult === "inside";
    const newStatus = computeNewStatus(app, boardId, inside, hasAlarm, effectivePrev === "n" ? null : effectivePrev);

    return newStatus;
}

function toSleepStatus(activeStatus) {
    return ACTIVE_TO_SLEEP[activeStatus] ?? "z";
}

function removeToken(app, userId, tokenToRemove) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return;

        const tokenString = user.getString("tokenFCM");
        if (!tokenString) return;

        let tokens = JSON.parse(tokenString);
        if (!Array.isArray(tokens)) return;

        // Filtra l'array mantenendo solo i token diversi da quello non valido
        const newTokens = tokens.filter(t => t !== tokenToRemove);

        // Salva solo se l'array è effettivamente cambiato
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
                    // Catturiamo la risposta della chiamata HTTP
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

                    // GESTIONE ERRORI FCM
                    // 404: UNREGISTERED (App disinstallata)
                    // 400: INVALID_ARGUMENT (Token malformato)
                    if (response.statusCode === 404 || response.statusCode === 400) {
                        console.log(`[FCM] Rilevato token non valido per utente ${userId}. Procedo alla rimozione.`);
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