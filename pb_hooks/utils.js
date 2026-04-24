// ═══════════════════════════════════════════════════════════════
// File: utils.js
// ═══════════════════════════════════════════════════════════════
 
const GPS_FAIL_ALERT_THRESH = 3;
const SESSION_DEDUP_SEC     = 30;
const WATCHDOG_TIMEOUT_MIN  = 10;
const BRIDGE_URL            = "http://127.0.0.1:3000/send";
 
// ── Mappa stato sleep → stato attivo di ritorno ──────────────────────────────
const SLEEP_TO_ACTIVE = { p: "s", d: "i", h: "f", z: "w" };
 
// ── Mappa stato attivo → stato sleep corrispondente ──────────────────────────
// "n" → "n": nessuna geofence, il sleep non cambia significato
const ACTIVE_TO_SLEEP = { s: "p", i: "d", f: "h", w: "z", n: "n" };
 
// ── Stati attivi (il cane è sveglio e si muove) ──────────────────────────────
const ACTIVE_STATES = new Set(["i", "s", "f", "w", "n"]);
 
// ── Stati sleep ───────────────────────────────────────────────────────────────
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
 
function getTokenUsers(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return null;
        const token = user.getString("tokenFCM");
        return token ? token : null;
    } catch (err) {
        console.log(`[GET TOKEN] Utente ${userId} non trovato o errore: ` + err);
        return null;
    }
}
 
function getUserAlarm(app, userId) {
    try {
        const user = app.findRecordById("users", userId);
        if (!user) return false;
        return user.getBool("alarm");
    } catch (err) {
        console.log(`[GET ALARM] Utente ${userId} errore: ` + err);
        return false;
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
 
/**
 * Verifica la posizione rispetto alle geofence attive.
 * Restituisce:
 *   "no_geofence" → nessuna geofence attiva configurata per la board
 *   "inside"      → dentro almeno una geofence
 *   "outside"     → fuori da tutte le geofence
 */
function getGeofenceStatus(app, boardId, lat, lon) {
    try {
        const geofences = app.findRecordsByFilter(
            "geofences",
            "board_id = {:bId} && is_active = true",
            "", 0, 0,
            { bId: boardId }
        );
 
        if (!geofences || geofences.length === 0) {
            console.log(`[GEOFENCE] Nessuna geofence attiva per board ${boardId}`);
            return "no_geofence";
        }
 
        for (const fence of geofences) {
            const fenceName = fence.getString("name");
            let vertices;
            try {
                const raw = fence.get("vertices");
                vertices = typeof raw === "string" ? JSON.parse(raw) : raw;
            } catch (parseErr) {
                console.log(`[GEOFENCE] Errore parse vertices "${fenceName}": ` + parseErr);
                continue;
            }
            if (!Array.isArray(vertices) || vertices.length < 3) continue;
            if (pointInPolygon(lat, lon, vertices)) {
                console.log(`[GEOFENCE] "${fenceName}" → DENTRO`);
                return "inside";
            }
        }
 
        return "outside";
    } catch (err) {
        console.log("[GEOFENCE getGeofenceStatus ERRORE] " + err);
        return "outside";
    }
}
 
/**
 * Calcola il nuovo status attivo in base alla posizione e all'alarm.
 *
 * Tabella transizioni:
 *  prevStatus | inside | hasAlarm | newStatus | notifica
 *  -----------|--------|----------|-----------|-----------------------------
 *  i          | true   | *        | i         | —
 *  i          | false  | true     | s         | "Uscita dalla zona"
 *  i          | false  | false    | w         | "Animale in passeggiata"
 *  s          | true   | *        | i         | "Rientrato in autonomia"
 *  s          | false  | true     | s         | — (rimane, già notificato)
 *  s          | false  | false    | f         | "Trovato!"
 *  f          | true   | *        | i         | "Rientrato accompagnato"
 *  f          | false  | *        | f         | —
 *  w          | true   | *        | i         | —
 *  w          | false  | true     | s         | "Ricerca attivata"
 *  w          | false  | false    | w         | —
 *  n/null     | true   | *        | i         | —
 *  n/null     | false  | true     | s         | "Uscita dalla zona"
 *  n/null     | false  | false    | w         | —
 */
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
            // alarm=true e ancora fuori: rimane "s" senza rinotificare
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
            // status null, "n" o sconosciuto: determina dalla posizione
            // "n" trattato come default perché ora ha una geofence → ricalcola
            if (inside) return "i";
            if (hasAlarm) {
                notifyBoardUsers(app, boardId, "🚨 Uscita dalla zona", "L'animale è uscito dalla zona monitorata", true);
                return "s";
            }
            return "w";
    }
}
 
/**
 * Punto di ingresso geofence: raccoglie contesto e chiama computeNewStatus.
 * Gestisce il risveglio dal sleep e il caso "nessuna geofence attiva" → "n".
 */
function checkGeofences(app, boardId, lat, lon, prevStatus) {
    const userIds  = getBoardUsers(app, boardId);
    const hasAlarm = userIds.some(uid => getUserAlarm(app, uid));
 
    // Risolvi lo stato attivo effettivo (scarta suffisso sleep)
    let effectivePrev = prevStatus;
    if (SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
        console.log(`[GEOFENCE] Risveglio da sleep "${prevStatus}" → ripristino stato "${effectivePrev}"`);
    }
 
    if (!lat && !lon) {
        // Nessuna posizione GPS valida: mantieni lo stato corrente
        console.log(`[GEOFENCE] GPS non valido per board ${boardId}, status invariato`);
        return effectivePrev ?? "n";
    }
 
    const geoResult = getGeofenceStatus(app, boardId, lat, lon);
 
    // Nessuna geofence configurata → status "n"
    if (geoResult === "no_geofence") {
        console.log(`[GEOFENCE] board=${boardId} nessuna geofence attiva → "n"`);
        return "n";
    }
 
    // Da "n" con geofence ora presenti → tratta come stato neutro (default)
    const inside = geoResult === "inside";
    const newStatus = computeNewStatus(app, boardId, inside, hasAlarm, effectivePrev === "n" ? null : effectivePrev);
 
    console.log(`[GEOFENCE] board=${boardId} inside=${inside} alarm=${hasAlarm} "${effectivePrev}" → "${newStatus}"`);
    return newStatus;
}
 
/**
 * Converte uno stato attivo nel corrispondente stato sleep.
 * "n" rimane "n" — nessuna geofence, il sleep non cambia significato.
 */
function toSleepStatus(activeStatus) {
    return ACTIVE_TO_SLEEP[activeStatus] ?? "z";
}
 
/**
 * Invia una notifica push a tutti gli utenti della board.
 * onlyAlarm=true → invia solo agli utenti con alarm=true.
 */
function notifyBoardUsers(app, boardId, title, body, onlyAlarm = false) {
    try {
        const userIds = getBoardUsers(app, boardId);
        if (userIds.length === 0) return;
 
        userIds.forEach(userId => {
            try {
                if (onlyAlarm && !getUserAlarm(app, userId)) return;
 
                const fcmToken = getTokenUsers(app, userId);
                if (!fcmToken) return;
 
                $http.send({
                    url:     BRIDGE_URL,
                    method:  "POST",
                    headers: { "Content-Type": "application/json" },
                    body:    JSON.stringify({
                        token: fcmToken,
                        title: title,
                        body:  `Board ${boardId}: ${body}`
                    })
                });
                console.log(`[NOTIFY] Inviato a ${userId}: ${title}`);
            } catch (uErr) {
                console.log("Errore invio singolo utente: " + uErr);
            }
        });
    } catch (err) {
        console.log("[NOTIFY ERRORE] " + err);
    }
}
 
module.exports = {
    GPS_FAIL_ALERT_THRESH,
    SESSION_DEDUP_SEC,
    WATCHDOG_TIMEOUT_MIN,
    SLEEP_TO_ACTIVE,
    ACTIVE_TO_SLEEP,
    ACTIVE_STATES,
    SLEEP_STATES,
    salvaEvento,
    notifyBoardUsers,
    pointInPolygon,
    getGeofenceStatus,
    checkGeofences,
    computeNewStatus,
    toSleepStatus
};
 