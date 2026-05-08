// ═══════════════════════════════════════════════════════════════
// File: main.pb.js  ← unico file *.pb.js, caricato da PocketBase
// ═══════════════════════════════════════════════════════════════
//
// Struttura moduli:
//   constants.js        — costanti condivise (stati, timeout, URL)
//   utils.js            — helpers board, batteria, notifiche, geofence, computeStatus
//   activity_manager.js — macchina a stati activity (STEP 1-2-3-4)
//
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
// HOOK: Smistamento dati — data_sent_raw
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    console.log("[DEBUG] Hook data_sent_raw attivato per record " + e.record.id);

    let utils, activityManager;
    try {
        utils           = require(`${__hooks}/utils.js`);
        activityManager = require(`${__hooks}/activity_manager.js`);
    } catch (err) {
        console.log("[DEBUG] ERRORE CRITICO: Impossibile caricare moduli: " + err);
        e.next();
        return;
    }

    console.log("[DEBUG] Moduli caricati correttamente, inizio estrazione dati...");

    const raw       = e.record;
    const imei      = raw.getString("board_id");
    const timestamp = raw.getString("timestamp");
    const sleep     = raw.getBool("sleep");
    const trip      = raw.getBool("trip");
    const steps     = raw.getInt("steps");
    const lat       = raw.getFloat("lat");
    const lon       = raw.getFloat("lon");
    const hasCoords = !(lat === 0.0 && lon === 0.0);

    try {
        const board = utils.getBoardRecord(e.app, imei);
        if (!board) {
            console.log(`[DEBUG] ERRORE: Board non trovata per IMEI ${imei}`);
            return;
        }

        console.log(`[DEBUG] Inizio processing pacchetto | BoardID: ${board.id} | Status: Sleep=${sleep}, Trip=${trip}, Steps=${steps}`);

        // ── 1. BATTERIA ──────────────────────────────────────────────────────
        console.log(`[DEBUG] Salvataggio dati batteria: level=${raw.getInt("battery_percent")}% | charging=${raw.getBool("charging")}`);
        utils.saveBattery(
            e.app,
            board.id,
            timestamp,
            raw.getFloat("battery"),
            raw.getInt("battery_percent"),
            raw.getBool("charging"),
            board
        );

        // ── 2. ACTIVITY: Macchina a stati ────────────────────────────────────
        const activeActivity = activityManager.processActivity(
            e.app,
            utils,
            board,
            timestamp,
            sleep,
            trip,
            steps,
            lat,
            lon
        );

        // null = pacchetto sleep scartato (sleep duplicato senza activity attiva)
        if (activeActivity === null) return;

        // ── 3. POSIZIONI ─────────────────────────────────────────────────────
        if (hasCoords && activeActivity) {
            utils.savePosition(
                e.app,
                board.id,
                timestamp,
                lat,
                lon,
                activeActivity.id
            );
        }

    } catch (err) {
        console.log("[DEBUG] ERRORE CRITICO HOOK: " + err);
    } finally {
        /*try {
            e.delete();
        } catch (delErr) {
            console.log("[DEBUG] ERRORE ELIMINAZIONE RECORD: " + delErr);
        }
        console.log("[DEBUG] Record raw eliminato con successo da data_sent_raw");
        */
        e.next();
    }
}, "data_sent_raw");


// ═══════════════════════════════════════════════════════════════
// WATCHDOG: chiude activity bloccate da troppo tempo
// Eseguito ogni minuto.
// ═══════════════════════════════════════════════════════════════

cronAdd("watchdog_device_silence", "* * * * *", () => {
    let utils, WATCHDOG_TIMEOUT_MS;
    try {
        utils                    = require(`${__hooks}/utils.js`);
        ({ WATCHDOG_TIMEOUT_MS } = require(`${__hooks}/constants.js`));
    } catch (err) {
        console.log("[WATCHDOG] ERRORE CRITICO caricamento moduli: " + err);
        return;
    }

    const oraAttualeMS = Date.now();

    try {
        // Limit 0 = nessun limite: controlla TUTTE le activity attive
        const activeActivities = $app.findRecordsByFilter(
            "activities",
            "is_active = true",
            "",
            0,
            0
        );

        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const endTimeStr = activity.getString("end_time");

            if (!endTimeStr) return;

            const lastSeenMs = Date.parse(endTimeStr.replace(" ", "T"));
            const elapsedMS  = oraAttualeMS - lastSeenMs;
            const elapsedMin = elapsedMS / 60000;

            console.log(`[WATCHDOG] Board: ${boardId} | Delta: ${elapsedMin.toFixed(2)} min`);

            if (!isNaN(elapsedMS) && elapsedMS >= WATCHDOG_TIMEOUT_MS) {
                console.log(`[WATCHDOG] → Scaduto! Chiusura board ${boardId}`);
                activity.set("is_active", false);
                activity.set("anomaly",   true);
                $app.save(activity);

                const board = utils.getBoardRecord($app, boardId);
                
                utils.notifyBoardUsers(
                    $app,
                    board,
                    boardId,
                    "⚠️ Dispositivo silenzioso",
                    "Il dispositivo non invia dati da più di 10 minuti mentre è in attività. Segnale GPS o Internet assenti"
                );
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});


// ═══════════════════════════════════════════════════════════════
// CRON MEZZANOTTE: split giornaliero a mezzanotte italiana
//
// Schedulato su "59 21,22 * * *" per coprire ora legale e solare:
//  - Estate CEST (UTC+2): scatta alle 21:59 UTC = 23:59 italiana ✓
//                         scatta alle 22:59 UTC = 00:59 italiana → skip
//  - Inverno CET (UTC+1): scatta alle 22:59 UTC = 23:59 italiana ✓
//                         scatta alle 21:59 UTC = 22:59 italiana → skip
//
// Il check interno italyHour===23 filtra il tick non pertinente.
//
// Per ogni board:
//  - Activity attiva      → chiude a fine giorno UTC, apre nuova a inizio giorno UTC
//  - Activity in sleep    → chiude il sleep a fine giorno UTC, apre nuovo sleep
//  - Activity con anomaly → ignorata (già gestita dal watchdog)
// ═══════════════════════════════════════════════════════════════

cronAdd("midnight_sleep_split", "59 21,22 * * *", () => {
    let utils, WATCHDOG_TIMEOUT_MS;
    try {
        utils                    = require(`${__hooks}/utils.js`);
        ({ WATCHDOG_TIMEOUT_MS } = require(`${__hooks}/constants.js`));
    } catch (err) {
        console.log("[MEZZANOTTE] ERRORE CRITICO caricamento moduli: " + err);
        return;
    }

    const italyNowMs = utils.getItalyTime();
    const nowUTC     = new Date();
    const offsetMs   = italyNowMs - nowUTC.getTime(); // 7200000 estate, 3600000 inverno

    const italyNow    = new Date(italyNowMs);
    const italyHour   = italyNow.getUTCHours();
    const italyMinute = italyNow.getUTCMinutes();

    if (italyHour !== 23 || italyMinute !== 59) {
        console.log(`[MEZZANOTTE] ora Italia: ${italyHour}:${italyMinute < 10 ? "0" : ""}${italyMinute} — skip`);
        return;
    }

    console.log(`[MEZZANOTTE] ora Italia: 23:59 — avvio split giornaliero`);

    // Mezzanotte italiana → convertita in UTC reale sottraendo l'offset dinamico
    const midnightItaly = new Date(Date.UTC(
        italyNow.getUTCFullYear(),
        italyNow.getUTCMonth(),
        italyNow.getUTCDate() + 1,
        0, 0, 0
    ));
    const midnightUTC = new Date(midnightItaly.getTime() - offsetMs);

    const fineGiornoISO   = new Date(midnightUTC.getTime() - 1000).toISOString(); // 21:59:59 UTC (estate) / 22:59:59 UTC (inverno)
    const inizioGiornoISO = midnightUTC.toISOString();                            // 22:00:00 UTC (estate) / 23:00:00 UTC (inverno)

    console.log(`[MEZZANOTTE] fine=${fineGiornoISO} | inizio=${inizioGiornoISO}`);

    try {
        // Prende solo activity attive O in stato sleep senza anomalia
        const targetActivities = $app.findRecordsByFilter(
            "activities",
            "is_active = true || (is_active = false && anomaly != true && (status = 'd' || status = 'p' || status = 'z' || status = 'a'))",
            "",
            0,
            0
        );
        if (!targetActivities || targetActivities.length === 0) return;

        // Per ogni board tiene solo la activity con end_time più recente
        const latestByBoard = {};
        targetActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const lastSeenMs = Date.parse(activity.getString("end_time").replace(" ", "T"));

            if (!latestByBoard[boardId] || lastSeenMs > latestByBoard[boardId].lastSeenMs) {
                latestByBoard[boardId] = { activity, lastSeenMs };
            }
        });

        // Carica la collection una volta sola fuori dal loop
        const col = $app.findCollectionByNameOrId("activities");

        Object.entries(latestByBoard).forEach(([boardId, { activity, lastSeenMs }]) => {
            try {
                const isActive = activity.getBool("is_active");
                const status   = activity.getString("status");

                // Activity attiva scaduta: il watchdog se ne è già occupato → skip
                if (isActive) {
                    const elapsed = italyNowMs - lastSeenMs;
                    if (!isNaN(elapsed) && elapsed >= WATCHDOG_TIMEOUT_MS) {
                        console.log(`[MEZZANOTTE] Board ${boardId} scaduta (watchdog) → skip`);
                        return;
                    }
                }

                if (isActive) {
                    // Chiude la sessione attiva e apre quella del giorno nuovo
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
                    console.log(`[MEZZANOTTE] Board ${boardId} attiva → split con status "${status}"`);

                } else if (utils.SLEEP_STATES.has(status)) {
                    // Chiude il record sleep del giorno corrente e apre quello del giorno nuovo
                    const wakeStatus = utils.SLEEP_TO_ACTIVE[status];
                    activity.set("status",   wakeStatus);
                    activity.set("end_time", fineGiornoISO);
                    $app.save(activity);

                    const newSleep = new Record(col);
                    newSleep.set("board_id",   boardId);
                    newSleep.set("start_time", inizioGiornoISO);
                    newSleep.set("end_time",   inizioGiornoISO);
                    newSleep.set("is_active",  false);
                    newSleep.set("status",     status);
                    $app.save(newSleep);
                    console.log(`[MEZZANOTTE] Board ${boardId} sleep "${status}" → split, sveglia come "${wakeStatus}"`);
                }

            } catch (err) {
                console.log(`[MEZZANOTTE] Errore board ${boardId}: ` + err);
            }
        });

    } catch (err) {
        console.log("[MEZZANOTTE] Errore generale: " + err);
    }
});
