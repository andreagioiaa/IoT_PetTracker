// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati — data_sent_raw
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);

    const raw       = e.record;
    const boardId   = raw.getString("board_id");
    const timestamp = raw.getString("timestamp");
    const sleep     = raw.getBool("sleep");
    const trip      = raw.getBool("trip");
    const steps     = raw.getInt("steps");
    const lat       = raw.getFloat("lat");
    const lon       = raw.getFloat("lon");
    const hasCoords = !(lat === 0.0 && lon === 0.0);

    try {
        const board = utils.getBoardRecord(e.app, boardId);

        // ── TRIP HOLD: Gestione Falsi Positivi Viaggio ──────────────────────
        let pendingTrip = null;
        try {
            const pendingRaw = board ? board.getString("pending_trip") : null;
            if (pendingRaw) pendingTrip = JSON.parse(pendingRaw);
        } catch (err) { pendingTrip = null; }

        // Se sleep=true, cancella subito ogni eventuale hold pendente
        if (sleep && pendingTrip) {
            if (board) {
                board.set("pending_trip", null);
                e.app.save(board);
            }
            pendingTrip = null;
        }

        // Logica di Filtro Trip (Richiede 2 messaggi consecutivi trip=true)
        if (trip && !sleep) {
            if (!pendingTrip) {
                // PRIMO trip=true: Metti in HOLD e salva i dati
                const holdData = {
                    timestamp, lat, lon, steps,
                    battery: raw.getFloat("battery"),
                    battery_percent: raw.getInt("battery_percent"),
                    charging: raw.getBool("charging")
                };
                if (board) {
                    board.set("pending_trip", JSON.stringify(holdData));
                    e.app.save(board);
                }
                // Processa batteria ma non salvare posizione/activity[cite: 3]
                utils.saveBattery(e.app, boardId, timestamp, holdData.battery, holdData.battery_percent, holdData.charging);
                e.next(); return; 
            } else {
                // SECONDO trip=true: Viaggio CONFERMATO[cite: 3]
                utils.saveBattery(e.app, boardId, pendingTrip.timestamp, pendingTrip.battery, pendingTrip.battery_percent, pendingTrip.charging);
                if (board) {
                    board.set("pending_trip", null);
                    e.app.save(board);
                }
            }
        }

        // Se trip=false ma avevamo un pending, era un falso positivo: recupera GPS[cite: 3]
        if (!trip && pendingTrip) {
            if (board) {
                board.set("pending_trip", null);
                e.app.save(board);
            }
            // Salvataggio ritardato della posizione del pacchetto in hold[cite: 3]
            utils.savePositionDelayed(e.app, boardId, pendingTrip);
            pendingTrip = null;
        }

        // ── 1. BATTERIA (Pacchetto attuale) ──────────────────────────────────
        utils.saveBattery(e.app, boardId, timestamp, raw.getFloat("battery"), raw.getInt("battery_percent"), raw.getBool("charging"));

        // ── 2. ACTIVITY: Macchina a Stati ────────────────────────────────────
        let activeActivity = null;
        const activeList = e.app.findRecordsByFilter("activities", "board_id = {:id} && is_active = true", "-end_time", 1, 0, { id: boardId });
        let currentActivity = activeList.length > 0 ? activeList[0] : null;

        if (currentActivity) {
            // --- GESTIONE SESSIONE ATTIVA ---
            const prevStatus = currentActivity.getString("status");
            const newActiveStatus = utils.computeStatus(e.app, board, boardId, lat, lon, trip, steps, prevStatus);

            if (sleep) {
                // Transizione verso lo Sleep: chiude l'activity[cite: 3, 4]
                const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z";
                currentActivity.set("is_active", false);
                currentActivity.set("end_time",  timestamp);
                currentActivity.set("status",    sleepStatus);
                e.app.save(currentActivity);
                activeActivity = currentActivity;
            } else {
                // Aggiornamento o Cambio Stato in tempo reale[cite: 3]
                if (newActiveStatus === prevStatus) {
                    currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
                    currentActivity.set("end_time", timestamp);
                    e.app.save(currentActivity);
                    activeActivity = currentActivity;
                } else {
                    // Cambio stato: chiudi vecchia e apri nuova[cite: 3]
                    currentActivity.set("is_active", false);
                    currentActivity.set("end_time", timestamp);
                    e.app.save(currentActivity);

                    activeActivity = utils.createNewActivity(e.app, boardId, timestamp, newActiveStatus, steps);
                }
            }
        } else {
            // --- GESTIONE RISVEGLIO O NUOVA SESSIONE ---
            const recentList = e.app.findRecordsByFilter("activities", "board_id = {:id} && is_active = false", "-end_time", 1, 0, { id: boardId });
            const recentClosed = recentList.length > 0 ? recentList[0] : null;
            const prevStatus = recentClosed ? recentClosed.getString("status") : null;

            const newActiveStatus = utils.computeStatus(e.app, board, boardId, lat, lon, trip, steps, prevStatus);

            if (sleep) {
                if (recentClosed) activeActivity = recentClosed;
            } else {
                if (recentClosed) {
                    const closedStatus = recentClosed.getString("status");
                    const isClosedSleep = utils.SLEEP_STATES.has(closedStatus);
                    
                    // Mappa lo stato sleep (d,a,p,z) al suo attivo (i,v,s,w)
                    const closedOrigin = isClosedSleep ? (utils.SLEEP_TO_ACTIVE[closedStatus] ?? closedStatus) : closedStatus;
                    const sameSituation = (closedOrigin === newActiveStatus);
                    
                    const diffSec = (new Date(timestamp) - new Date(recentClosed.getString("end_time").replace(" ", "T"))) / 1000;

                    // RIPRENDE solo se la situazione è IDENTICA[cite: 3]
                    if (isClosedSleep && !recentClosed.getBool("anomaly") && sameSituation) {
                        recentClosed.set("is_active", true);
                        recentClosed.set("status", newActiveStatus);
                        recentClosed.set("end_time", timestamp);
                        recentClosed.set("total_steps", recentClosed.getInt("total_steps") + steps);
                        e.app.save(recentClosed);
                        activeActivity = recentClosed;
                    } 
                    // DEDUP: se attivo e stessa situazione entro timeout[cite: 3]
                    else if (!isClosedSleep && diffSec < utils.SESSION_DEDUP_SEC && sameSituation) {
                        recentClosed.set("is_active", true);
                        recentClosed.set("end_time", timestamp);
                        e.app.save(recentClosed);
                        activeActivity = recentClosed;
                    }
                    else {
                        // SITUAZIONE CAMBIATA: Nuova Activity[cite: 3]
                        activeActivity = utils.createNewActivity(e.app, boardId, timestamp, newActiveStatus, steps);
                    }
                } else {
                    activeActivity = utils.createNewActivity(e.app, boardId, timestamp, newActiveStatus, steps);
                }
            }
        }

        // ── 3. POSIZIONI ─────────────────────────────────────────────────────
        if (hasCoords && activeActivity) {
            const colP = e.app.findCollectionByNameOrId("positions");
            const recP = new Record(colP);
            recP.set("board_id", boardId);
            recP.set("timestamp", timestamp);
            recP.set("lat", lat);
            recP.set("lon", lon);
            recP.set("activity", activeActivity.id);
            e.app.save(recP);
        }

    } catch (err) {
        console.log("ERRORE CRITICO: " + err);
    } finally {
        e.app.delete(raw);
        e.next();
    }
}, "data_sent_raw");


// ═══════════════════════════════════════════════════════════════
//  HOOK: Notifiche al cambio status su activities (onCreate)
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils   = require(`${__hooks}/utils.js`);
    const record  = e.record;
    const boardId = record.getString("board_id");
    const status  = record.getString("status");

    const eventMap = {
        "i": ["status_inside",      "Animale nella zona sicura"],
        "v": ["status_trip",        "Animale in viaggio su veicolo"],
        "s": ["status_search",      "Animale fuori zona — ricerca attiva"],
        "w": ["status_walk",        "Animale in passeggiata"],
        "d": ["status_sleep_i",     "Animale a riposo in zona sicura"],
        "a": ["status_trip_sleep",  "Animale in sleep durante il viaggio"],
        "p": ["status_sleep_s",     "Animale a riposo fuori zona (allarme)"],
        "z": ["status_sleep_w",     "Animale a riposo fuori zona (passeggiata)"],
    };

    try {
        const entry = eventMap[status];
        if (entry) utils.salvaEvento(e.app, boardId, entry[0], entry[1]);
    } catch (err) {
        console.log("[ACTIVITY CREATE HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");


// ═══════════════════════════════════════════════════════════════
//  HOOK: Notifiche al cambio status su activities (onUpdate)
// ═══════════════════════════════════════════════════════════════

onRecordAfterUpdateSuccess((e) => {
    const utils   = require(`${__hooks}/utils.js`);
    const record  = e.record;
    const boardId = record.getString("board_id");
    const status  = record.getString("status");
    const isActive = record.getBool("is_active");

    if (!isActive) { e.next(); return; }

    const eventMap = {
        "v": ["status_trip",   "Animale in viaggio su veicolo"],
        "i": ["status_inside", "Animale rientrato in zona sicura"],
        "s": ["status_search", "Animale fuori zona — ricerca attiva"],
        "w": ["status_walk",   "Animale in passeggiata"],
    };

    try {
        const entry = eventMap[status];
        if (entry) utils.salvaEvento(e.app, boardId, entry[0], entry[1]);
    } catch (err) {
        console.log("[ACTIVITY UPDATE HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");


// ═══════════════════════════════════════════════════════════════
//  CRON 1: Watchdog inattività — ogni minuto
// ═══════════════════════════════════════════════════════════════
cronAdd("watchdog_device_silence", "* * * * *", () => {
    const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000;
    const utils = require(`${__hooks}/utils.js`);

    // FIX7: offset Italia dinamico — gestisce ora legale/solare automaticamente
    const oraRiferimento = utils.getItalyTime();

    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 100, 0);
        if (!activeActivities || activeActivities.length === 0) return;

        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const status     = activity.getString("status");
            const endTimeStr = activity.getString("end_time");

            if (!endTimeStr) return;

            // Sleep sempre is_active=false per design, questo è solo salvaguardia
            if (utils.SLEEP_STATES.has(status)) {
                console.log(`[WATCHDOG] board=${boardId} skip sleep "${status}"`);
                return;
            }

            //const lastSeenMs = Date.parse(endTimeStr.replace(" ", "T"));
            const lastSeenMs = Date.parse(endTimeStr.replace(" ", "T")) + (2 * 60 * 60 * 1000);
            const elapsed    = oraRiferimento - lastSeenMs;

            console.log(`[WATCHDOG] board=${boardId} | inattiva da: ${(elapsed / 60000).toFixed(2)} min`);

            if (!isNaN(elapsed) && elapsed >= WATCHDOG_TIMEOUT_MS) {
                activity.set("is_active", false);
                activity.set("anomaly",   true);
                $app.save(activity);

                // FIX5: cancella il pending_trip se il device va offline
                try {
                    const board = utils.getBoardRecord($app, boardId);
                    if (board && board.getString("pending_trip")) {
                        board.set("pending_trip", null);
                        $app.save(board);
                        console.log(`[WATCHDOG] board=${boardId} pending_trip cancellato`);
                    }
                } catch (err) { console.log("[WATCHDOG] Errore cancella pending: " + err); }

                utils.salvaEvento($app, boardId, "watchdog", `Chiusura per inattività (status: ${status})`);
                console.log(`[WATCHDOG] -> CHIUSA board=${boardId} per inattività.`);
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});


// ═══════════════════════════════════════════════════════════════
//  CRON 2: Mezzanotte — split giornaliero
//
//  FIX7: il cron gira alle 21:59 UTC come base, ma la logica interna
//  usa getItalyTime() per calcolare l'ora italiana reale e verificare
//  che sia effettivamente mezzanotte (23:00-00:00) prima di procedere.
//  Questo gestisce automaticamente ora legale (UTC+2) e solare (UTC+1).
// ═══════════════════════════════════════════════════════════════
cronAdd("midnight_sleep_split", "59 21 * * *", () => {
    const utils = require(`${__hooks}/utils.js`);
    const SLEEP_TO_ACTIVE_MAP = { d: "i", p: "s", z: "w", a: "v" };
    const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000;

    // FIX7: calcola l'ora italiana reale con offset dinamico
    const italyNowMs   = utils.getItalyTime();
    const italyNow     = new Date(italyNowMs);
    const italyHour    = italyNow.getUTCHours();
    const italyMinute  = italyNow.getUTCMinutes();

    // Verifica che sia effettivamente le 23:59 in Italia
    // Il cron gira alle 21:59 UTC (ora legale) e alle 22:59 UTC (ora solare).
    // Se non è 23:59 in Italia, esci senza fare nulla.
    if (italyHour !== 23 || italyMinute !== 59) {
        console.log(`[MEZZANOTTE] ora Italia: ${italyHour}:${italyMinute < 10 ? "0" : ""}${italyMinute} — skip`);
        return;
    }

    console.log(`[MEZZANOTTE] ora Italia: 23:59 — avvio split giornaliero`);

    // Calcola fine giorno e inizio giorno successivo in ora italiana
    const fineGiornoISO   = new Date(italyNow.getFullYear(), italyNow.getMonth(), italyNow.getDate(), 23, 59, 59).toISOString();
    const inizioGiornoISO = new Date(italyNow.getFullYear(), italyNow.getMonth(), italyNow.getDate() + 1, 0, 0, 0).toISOString();

    try {
        const targetActivities = $app.findRecordsByFilter(
            "activities",
            "is_active = true || (is_active = false && (status = 'd' || status = 'p' || status = 'z' || status = 'a'))",
            "", 500, 0
        );
        if (!targetActivities) return;

        // Raggruppa per board, tieni solo la più recente
        const latestByBoard = {};
        targetActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const lastSeenMs = Date.parse(activity.getString("end_time").replace(" ", "T"));
            if (!latestByBoard[boardId] || lastSeenMs > latestByBoard[boardId].lastSeenMs) {
                latestByBoard[boardId] = { activity, lastSeenMs };
            }
        });

        Object.entries(latestByBoard).forEach(([boardId, { activity, lastSeenMs }]) => {
            try {
                const isActive = activity.getBool("is_active");
                const status   = activity.getString("status");

                // Watchdog prima dello split
                if (isActive) {
                    const elapsed = italyNowMs - lastSeenMs;
                    if (!isNaN(elapsed) && elapsed >= WATCHDOG_TIMEOUT_MS) {
                        activity.set("is_active", false);
                        activity.set("anomaly",   true);
                        $app.save(activity);
                        return;
                    }
                }

                const col = $app.findCollectionByNameOrId("activities");

                if (isActive) {
                    activity.set("is_active", false);
                    activity.set("end_time",  fineGiornoISO);
                    $app.save(activity);

                    const newRec = new Record(col);
                    newRec.set("board_id",   boardId);
                    newRec.set("start_time", inizioGiornoISO);
                    newRec.set("end_time",   inizioGiornoISO);
                    newRec.set("is_active",  true);
                    newRec.set("status",     status);
                    $app.save(newRec);

                } else if (SLEEP_TO_ACTIVE_MAP[status]) {
                    // Tutti gli sleep uniformi, nessun caso speciale per "a"
                    const attivo = SLEEP_TO_ACTIVE_MAP[status];
                    activity.set("status",   attivo);
                    activity.set("end_time", fineGiornoISO);
                    $app.save(activity);

                    const newSleep = new Record(col);
                    newSleep.set("board_id",   boardId);
                    newSleep.set("start_time", inizioGiornoISO);
                    newSleep.set("end_time",   inizioGiornoISO);
                    newSleep.set("is_active",  false);
                    newSleep.set("status",     status);
                    $app.save(newSleep);
                }

            } catch (err) { console.log("Errore board " + boardId + ": " + err); }
        });
    } catch (err) { console.log("Errore Mezzanotte: " + err); }
});