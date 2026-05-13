// ═══════════════════════════════════════════════════════════════
// File: utils.js
// Funzioni helper: board, batteria, posizioni, notifiche, geofence, computeStatus
// ═══════════════════════════════════════════════════════════════
//
// FLUSSO computeStatus (priorità decrescente):
//
//  1. TRIP (alarm=false) -> "v"
//     TRIP (alarm=true)  -> "r"
//     Condizione: trip=true && steps==0
//     steps==0 evita falsi positivi su animale già in movimento
//
//  2. ERA IN VIAGGIO (trip=false, effectivePrev = "v" o "r")
//     steps==0 -> mantieni lo stato viaggio corrente
//     steps>0  -> l'animale è sceso, ricalcola geofence
//
//  3. INSIDE (geofence=true) -> "i"
//
//  4. OUTSIDE + alarm=true  -> "s"
//     OUTSIDE + alarm=false -> "w"
//
// NOTE:
//  - getBoardRecord: chiamare UNA SOLA VOLTA per pacchetto
//  - notifyBoardUsers: 1 query DB + 1 chiamata HTTP batch
//  - computeStatus: normalizza internamente i prevStatus sleep -> attivo
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
 *
 * Calcola dinamicamente l'offset UTC+1 (CET, ora solare) o UTC+2 (CEST, ora legale).
 * L'ora legale italiana inizia l'ultima domenica di marzo alle 02:00
 * e finisce l'ultima domenica di ottobre alle 03:00 (regole europee).
 *
 * @returns {number} - millisecondi epoch in ora italiana
 */
function getItalyTime() {
    const now  = new Date();
    const year = now.getUTCFullYear();

    // Ultima domenica di marzo: inizio ora legale (CEST, UTC+2)
    const lastSundayMarch = new Date(Date.UTC(year, 2, 31));
    lastSundayMarch.setUTCDate(31 - lastSundayMarch.getUTCDay());

    // Ultima domenica di ottobre: fine ora legale (CET, UTC+1)
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
 *
 * Chiamare UNA SOLA VOLTA per pacchetto e passare il risultato
 * ai metodi successivi per evitare query ridondanti.
 *
 * @param {object} app
 * @param {string} boardId - IMEI del dispositivo o id PocketBase
 * @returns {object|null}  - record board o null se non trovato
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
 *
 * @param {object|null} board - record board già letto
 * @returns {string[]}        - array di userId (può essere vuoto)
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
 *
 * @param {object|null} board - record board già letto
 * @returns {boolean}
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

/**
 * Salva un evento di sistema nella collection device_events.
 *
 * @param {object} app
 * @param {string} boardId
 * @param {string} type   - tipo evento (es. "alarm", "trip", "battery")
 * @param {string} detail - dettaglio testuale
 */
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
 * Salva il record battery_data e invia notifica push se lo stato è cambiato.
 *
 * Logica notifiche:
 *  - charging=true                -> "carica"   (notifica sempre al cambio)
 *  - percent <= 10 && !charging   -> "critical" (notifica una volta)
 *  - percent <= 20 && !charging   -> "low"      (notifica una volta)
 *  - percent >  20 && !charging   -> "ok"       (nessuna notifica)
 *
 * @param {object}  app
 * @param {string}  boardId
 * @param {string}  timestamp
 * @param {number}  battery        - voltaggio raw
 * @param {number}  batteryPercent - percentuale 0-100
 * @param {boolean} isCharging
 * @param {object|null} board      - record board già letto (null = skip notifiche)
 */
function saveBattery(app, boardId, timestamp, battery, batteryPercent, isCharging, board) {
    // 1. Salva sempre il record battery_data indipendentemente dalla board
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

    // 2. Controlla e invia notifica solo se board è disponibile
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
                console.log(`[BATTERY] board=${boardId} "${lastStatus}" -> "${newStatus}" (${batteryPercent}%)`);
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
 * @param {string} boardRecordId - id PocketBase della board (NON l'IMEI)
 * @param {string} timestamp
 * @param {string} status        - stato attivo: i, v, r, s, w
 * @param {number} steps
 * @returns {object}             - il record activity appena creato
 */
function createNewActivity(app, boardRecordId, timestamp, status, steps) {
    try {
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
    } catch (err) {
        // Se il salvataggio fallisce logga e restituisce null.
        // Il chiamante deve controllare il valore di ritorno prima di usarlo.
        console.log(`[ACTIVITY] ERRORE creazione activity board=${boardRecordId} status=${status}: ` + err);
        return null;
    }
}

/**
 * Salva una posizione GPS collegandola ad una activity.
 *
 * @param {object}      app
 * @param {string}      boardRecordId - id PocketBase della board
 * @param {string}      timestamp
 * @param {number}      lat
 * @param {number}      lon
 * @param {string|null} activityId    - id activity da collegare (null = non collegata)
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
 * Chiamata automaticamente dopo una risposta 404/400 dal bridge.
 *
 * @param {object} app
 * @param {string} userId
 * @param {string} tokenToRemove
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
 * Invia una notifica push a tutti gli utenti collegati alla board.
 *
 * Ottimizzazioni rispetto all'approccio naive:
 *  - 1 query DB per tutti gli utenti invece di N query separate
 *  - 1 chiamata HTTP batch al bridge invece di N chiamate singole
 *  - Il bridge parallelizza internamente con Promise.all verso FCM
 *  - I token invalidi vengono rimossi automaticamente dalla risposta bridge
 *
 * @param {object} app
 * @param {object|null} board  - record board già letto
 * @param {string} boardId
 * @param {string} title       - titolo notifica push
 * @param {string} body        - corpo notifica push
 */
function notifyBoardUsers(app, board, boardId, title, body) {
    try {
        const userIds = getBoardUsers(board);
        if (userIds.length === 0) {
            console.log(`[NOTIFY] Nessun utente per board=${boardId}`);
            return;
        }

        // ── Recupera ogni utente tramite id diretto ──────────────────────────
        // findRecordById è sicuro per qualsiasi formato di id e non richiede
        // interpolazione di stringhe nella query (nessun rischio injection)
        const users = userIds.reduce((acc, userId) => {
            try {
                const user = app.findRecordById("users", userId);
                if (user) acc.push(user);
            } catch (e) {
                console.log(`[NOTIFY] Utente ${userId} non trovato: ` + e);
            }
            return acc;
        }, []);

        if (users.length === 0) {
            console.log(`[NOTIFY] Nessun record utente trovato per board=${boardId}`);
            return;
        }

        // Raccoglie tutti i token FCM e costruisce la mappa token -> userId
        // per poter rimuovere i token invalidi segnalati dal bridge
        const allTokens    = [];
        const tokenUserMap = {}; // { "token_string": "userId" }

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

        // ── 1 chiamata HTTP batch: tutti i token in una sola richiesta ─────────
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
        // Il bridge restituisce { results: [...], invalidTokens: ["token1", ...] }
        if (response.statusCode === 200) {
            try {
                const data        = JSON.parse(response.body);
                const invalidList = data.invalidTokens || [];

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

/**
 * Algoritmo ray-casting per determinare se un punto è dentro un poligono.
 * Conta le intersezioni di un raggio orizzontale con i lati del poligono.
 * Numero dispari = dentro, numero pari = fuori.
 *
 * @param {number}   lat      - latitudine del punto
 * @param {number}   lon      - longitudine del punto
 * @param {number[][]} vertices - array di [lat, lon]
 * @returns {boolean}
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
 * Verifica se le coordinate sono dentro uno dei geofence attivi della board.
 *
 * @param {object} app
 * @param {string} boardId
 * @param {number} lat
 * @param {number} lon
 * @returns {"inside"|"outside"|"no_geofence"}
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
 * Calcola il nuovo stato attivo del dispositivo in base ai dati del pacchetto.
 *
 * PRIORITÀ (dal più alto al più basso):
 *  1. trip=true  -> "v" (alarm=false) o "r" (alarm=true)
 *  2. era in viaggio ("v"/"r") con steps==0 -> mantieni stato viaggio
 *  3. geofence inside -> "i"
 *  4. geofence outside + alarm=true  -> "s"
 *  5. geofence outside + alarm=false -> "w"
 *
 * Normalizzazione prevStatus:
 *  I prevStatus sleep (a, q, d, p, z) vengono convertiti nel corrispondente
 *  attivo prima di qualsiasi confronto, così la logica lavora sempre
 *  con stati attivi e non deve gestire entrambe le forme.
 *
 * @param {object}       app
 * @param {object|null}  board      - record board già letto
 * @param {string}       boardId
 * @param {number}       lat
 * @param {number}       lon
 * @param {boolean}      isTrip     - flag trip (già confermato al 2° pacchetto consecutivo)
 * @param {number}       steps
 * @param {string|null}  prevStatus - stato precedente attivo o sleep
 * @returns {string}                - nuovo stato attivo: i, v, r, s, w
 */
function computeStatus(app, board, boardId, lat, lon, isTrip, steps, prevStatus) {

    // ── Normalizzazione prevStatus sleep -> attivo ─────────────────────────────
    // Es: "a"->"v", "q"->"r", "d"->"i", "p"->"s", "z"->"w"
    // Consente alla logica sottostante di lavorare sempre con stati attivi
    let effectivePrev = prevStatus;
    if (prevStatus && SLEEP_STATES.has(prevStatus)) {
        effectivePrev = SLEEP_TO_ACTIVE[prevStatus] ?? null;
    }

    // ── 1. TRIP ──────────────────────────────────────────────────────────────
    // steps==0 evita falsi positivi: se l'animale è già in movimento
    // (steps>0) non era su un veicolo ma stava camminando.
    // alarm=false -> "v" (trip normale)
    // alarm=true  -> "r" (trip con allarme attivo)
    if (isTrip && steps === 0) {
        const hasAlarmTrip = getBoardAlarm(board);
        const tripStatus   = hasAlarmTrip ? "r" : "v";

        if (effectivePrev !== tripStatus) {
            const tripMsg = hasAlarmTrip
                ? { title: "🚨 Animale in viaggio (allarme)", body: "L'animale è su un veicolo con allarme attivo" }
                : { title: "🚗 Animale in viaggio",           body: "L'animale è su un veicolo" };
            notifyBoardUsers(app, board, boardId, tripMsg.title, tripMsg.body);
            console.log(`[TRIP] board=${boardId} ingresso in viaggio stato="${tripStatus}" (era: ${effectivePrev})`);
        }
        return tripStatus;
    }

    // ── 2. ERA IN VIAGGIO (trip=false) ───────────────────────────────────────
    // Se l'animale era in viaggio ("v" o "r") e steps==0:
    //   -> il veicolo si è fermato ma l'animale non ha ancora camminato,
    //     manteniamo lo stato viaggio per evitare transizioni premature.
    // Se steps>0:
    //   -> l'animale è sceso e si sta muovendo, ricalcoliamo geofence.
    const wasInTrip = effectivePrev === "v" || effectivePrev === "r";
    if (wasInTrip) {
        if (steps === 0) {
            console.log(`[TRIP] board=${boardId} trip=false ma steps==0, manteniamo "${effectivePrev}"`);
            return effectivePrev;
        }
        console.log(`[TRIP] board=${boardId} uscita viaggio con steps=${steps}, ricalcolo geofence`);
        // effectivePrev rimane "v"/"r" così i blocchi inside/outside
        // sanno che l'animale è appena sceso dal veicolo
    }

    // ── 3. INSIDE / OUTSIDE ──────────────────────────────────────────────────
    // Se non ci sono coordinate valide, manteniamo lo stato precedente
    const hasCoords = !(lat === 0.0 && lon === 0.0);
    if (!hasCoords) return effectivePrev ?? "w";

    const geoResult = getGeofenceStatus(app, boardId, lat, lon);

    // ── Nessuna geofence configurata ─────────────────────────────────────────
    // GEOFENCE_STATES = {"i","s"} — stati che richiedono geofence per essere validi
    // Se l'animale era in uno stato geofence-dipendente senza geofence -> "w"
    if (geoResult === "no_geofence") {
        if (effectivePrev && GEOFENCE_STATES.has(effectivePrev)) {
            console.log(`[GEOFENCE] board=${boardId} nessuna geofence, stato "${effectivePrev}" non valido -> "w"`);
            notifyBoardUsers(app, board, boardId, "Nessuna zona configurata", "Le zone di monitoraggio sono state disattivate");
            return "w";
        }
        if (wasInTrip) {
            notifyBoardUsers(app, board, boardId, "🐾 Cane sceso dal veicolo in passeggiata", "L'animale è sceso dal veicolo");
            return "w";
        }
        console.log(`[GEOFENCE] board=${boardId} nessuna geofence, manteniamo "${effectivePrev ?? "w"}"`);
        return effectivePrev ?? "w";
    }

    const inside   = geoResult === "inside";
    const hasAlarm = getBoardAlarm(board);

    // ── Inside geofence -> "i" ─────────────────────────────────────────────────
    if (inside) {
        if (effectivePrev !== "i") {
            const msgMap = {
                "s":  ["✅ Animale rientrato",       "L'animale è rientrato nella zona monitorata"],
                "w":  ["🏠 Animale rientrato",       "L'animale è tornato dalla passeggiata"],
                "v":  ["🏠 Arrivato a destinazione", "L'animale è sceso dal veicolo nella zona sicura"],
                "r":  ["🏠 Arrivato a destinazione", "L'animale è sceso dal veicolo nella zona sicura (allarme era attivo)"],
                null: ["🏠 Animale in zona",         "L'animale si trova nella zona sicura"],
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🏠 Animale in zona", "L'animale si trova nella zona sicura"];
            notifyBoardUsers(app, board, boardId, title, body);
        }
        return "i";
    }

    // ── Outside geofence + alarm=true -> "s" ──────────────────────────────────
    if (hasAlarm) {
        if (effectivePrev !== "s") {
            const msgMap = {
                "i":  ["🚨 Uscita dalla zona",         "L'animale è uscito dalla zona monitorata"],
                "w":  ["🚨 Ricerca attivata",          "Allarme attivato mentre l'animale era in passeggiata"],
                "v":  ["🚨 Cane scappato dal veicolo", "Allarme! L'animale è fuggito scendendo dal veicolo"],
                "r":  ["🚨 Cane scappato dal veicolo", "Allarme! L'animale è fuggito scendendo dal veicolo (allarme già attivo)"],
                null: ["🚨 Animale fuori zona",        "L'animale è fuori dalla zona monitorata"],
            };
            const [title, body] = msgMap[effectivePrev] ?? ["🚨 Animale fuori zona", "L'animale è fuori dalla zona monitorata"];
            notifyBoardUsers(app, board, boardId, title, body);
        }
        return "s";
    }

    // ── Outside geofence + alarm=false -> "w" ─────────────────────────────────
    if (effectivePrev !== "w") {
        const msgMap = {
            "i":  ["🐾 Animale in passeggiata",                "L'animale è uscito per una passeggiata"],
            "s":  ["🔍 Animale trovato",                       "L'animale è stato trovato"],
            "v":  ["🐾 Cane sceso dal veicolo in passeggiata", "L'animale ha iniziato una passeggiata"],
            "r":  ["🐾 Cane sceso dal veicolo in passeggiata", "L'animale ha iniziato una passeggiata (allarme disattivato)"],
            null: ["🐾 Animale rilevato",                      "L'animale è fuori dalla zona monitorata"],
        };
        const [title, body] = msgMap[effectivePrev] ?? ["🐾 Animale fuori zona", "L'animale si trova fuori dalla zona monitorata"];
        notifyBoardUsers(app, board, boardId, title, body);
    }
    return "w";
}

// ─────────────────────────────────────────────────────────────────────────────
// EXPORTS
// ─────────────────────────────────────────────────────────────────────────────

module.exports = {
    // Costanti ri-esportate per accesso diretto dai moduli che importano utils
    SLEEP_TO_ACTIVE,
    ACTIVE_TO_SLEEP,
    ACTIVE_STATES,
    SLEEP_STATES,
    GEOFENCE_STATES,
    // Tempo
    getItalyTime,
    // Board
    getBoardRecord,
    getBoardUsers,
    getBoardAlarm,
    // Dati
    saveBattery,
    createNewActivity,
    savePosition,
    salvaEvento,
    // Notifiche
    notifyBoardUsers,
    // Geofence & stato
    pointInPolygon,
    getGeofenceStatus,
    computeStatus,
};