// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati — data_sent_raw
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);

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
        utils.saveBattery(
            e.app,
            board.id,
            timestamp,
            raw.getFloat("battery"),
            raw.getInt("battery_percent"),
            raw.getBool("charging"),
            board
        );

        // ── 2. ACTIVITY: Macchina a Stati ────────────────────────────────────
        let activeActivity = null;

        // ── STEP 1: Cerca activity attiva ────────────────────────────────────
        const activeList = e.app.findRecordsByFilter(
            "activities",
            "board_id = {:id} && is_active = true",
            "-end_time",
            1,
            0,
            { id: board.id }
        );

        let currentActivity = activeList.length > 0 ? activeList[0] : null;
        console.log(`[DEBUG] Activity attiva trovata: ${currentActivity ? currentActivity.id : "nessuna"}`);

        // ── STEP 2: Calcolo nuovo stato ──────────────────────────────────────
        // Va fatto PRIMA del risveglio per confrontare col wakeStatus
        const newActiveStatus = utils.computeStatus(
            e.app,
            board,
            board.id,
            lat,
            lon,
            trip,
            steps,
            currentActivity ? currentActivity.getString("status") : null
        );
        console.log(`[DEBUG] Nuovo stato calcolato: ${newActiveStatus}`);

        // ── STEP 3: Logica di risveglio ──────────────────────────────────────
        // Solo se non c'è nessuna activity attiva
        if (!currentActivity) {
            const recentList = e.app.findRecordsByFilter(
                "activities",
                "board_id = {:id} && is_active = false && anomaly != true && (status = 'a' || status = 'z' || status = 'p' || status = 'd')",
                "-end_time",
                1,
                0,
                { id: board.id }
            );
            const recentClosed = recentList.length > 0 ? recentList[0] : null;

            // Log diagnostico: cosa ha trovato la query di risveglio
            console.log(`[DEBUG] Risveglio query: trovato=${recentClosed ? recentClosed.id : "null"} | status="${recentClosed ? recentClosed.getString("status") : "-"}" | anomaly=${recentClosed ? recentClosed.getBool("anomaly") : "-"} | isSleep=${recentClosed ? utils.SLEEP_STATES.has(recentClosed.getString("status")) : "-"}`);

            if (recentClosed && utils.SLEEP_STATES.has(recentClosed.getString("status"))) {
                const sleepStatus = recentClosed.getString("status");       // es. "p"
                const wakeStatus  = utils.SLEEP_TO_ACTIVE[sleepStatus];     // es. "p" → "s"

                // Converte SEMPRE il record sleep nel suo attivo corrispondente.
                // Chiude correttamente il periodo sleep indipendentemente dal nuovo stato.
                recentClosed.set("status", wakeStatus);
                e.app.save(recentClosed);
                console.log(`[DEBUG] Sleep chiuso correttamente: ${sleepStatus} -> ${wakeStatus}`);

                if (wakeStatus === newActiveStatus) {
                    // Stato conforme: riapre la sessione esistente
                    recentClosed.set("is_active", true);
                    e.app.save(recentClosed);
                    currentActivity = recentClosed;
                    console.log(`[DEBUG] Risveglio conforme: sessione ${recentClosed.id} riaperta in stato "${wakeStatus}"`);
                } else {
                    // Stato non conforme: sessione sleep resta chiusa col suo attivo,
                    // sotto verrà creata una nuova sessione col nuovo stato.
                    console.log(`[DEBUG] Risveglio non conforme: sleep="${sleepStatus}" wake="${wakeStatus}" nuovo="${newActiveStatus}" → nuova sessione`);
                }
            }
            // Se anomaly=true → currentActivity resta null → crea nuova sessione sotto
        }

        // ── STEP 4: Macchina a stati ─────────────────────────────────────────
        if (currentActivity) {
            const rawPrevStatus  = currentActivity.getString("status");
            const normalizedPrev = utils.SLEEP_TO_ACTIVE[rawPrevStatus] ?? rawPrevStatus;

            if (sleep) {
                // Dispositivo in sleep: chiude la sessione con lo stato sleep corrispondente
                const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z";
                currentActivity.set("is_active", false);
                currentActivity.set("end_time",  timestamp);
                currentActivity.set("status",    sleepStatus);
                e.app.save(currentActivity);
                activeActivity = currentActivity;
                console.log(`[DEBUG] Dispositivo in sleep: sessione chiusa con stato "${sleepStatus}"`);

            } else if (newActiveStatus === normalizedPrev) {
                // Stesso stato: estende la sessione corrente
                currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
                currentActivity.set("end_time", timestamp);
                e.app.save(currentActivity);
                activeActivity = currentActivity;

            } else {
                // Cambio stato: chiude la sessione corrente e ne apre una nuova
                console.log(`[DEBUG] Transizione stato: ${normalizedPrev} -> ${newActiveStatus}`);
                currentActivity.set("is_active", false);
                currentActivity.set("end_time",  timestamp);
                e.app.save(currentActivity);

                activeActivity = utils.createNewActivity(
                    e.app,
                    board.id,
                    timestamp,
                    newActiveStatus,
                    steps
                );
            }

        } else if (!sleep) {
            // Nessuna activity attiva e dispositivo sveglio → crea nuova sessione
            activeActivity = utils.createNewActivity(
                e.app,
                board.id,
                timestamp,
                newActiveStatus,
                steps
            );
        }
        // sleep=true e currentActivity=null → dispositivo già in sleep, non fare nulla

        // ── 3. POSIZIONI ─────────────────────────────────────────────────────
        if (hasCoords && activeActivity) {
            try {
                const idAttivita = activeActivity.id;

                if (!idAttivita) {
                    console.log("[DEBUG] ERRORE: activeActivity non ha un ID valido!");
                    return;
                }

                const colP = e.app.findCollectionByNameOrId("positions");
                const recP = new Record(colP);

                recP.set("board_id",  board.id);
                recP.set("timestamp", timestamp);
                recP.set("lat",       lat);
                recP.set("lon",       lon);
                recP.set("activity",  idAttivita);

                e.app.save(recP);
                console.log(`[DEBUG] OK! Posizione salvata e collegata all'activity: ${idAttivita}`);

            } catch (posErr) {
                console.log(`[DEBUG] FALLIMENTO POSIZIONE: ${posErr.toString()}`);
            }
        }

    } catch (err) {
        console.log("[DEBUG] ERRORE CRITICO HOOK: " + err);
    } finally {
        e.next();
    }
}, "data_sent_raw");


// ═══════════════════════════════════════════════════════════════
// WATCHDOG: chiude attività ferme
// ═══════════════════════════════════════════════════════════════

cronAdd("watchdog_device_silence", "* * * * *", () => {
    const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000; // 10 minuti
    const oraAttualeMS = Date.now();

    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 100, 0);

        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const endTimeStr = activity.getString("end_time");

            if (!endTimeStr) return;

            const lastSeenMs = Date.parse(endTimeStr.replace(" ", "T"));
            const elapsedMS  = oraAttualeMS - lastSeenMs;
            const elapsedMin = elapsedMS / 60000;

            console.log(`[WATCHDOG] Board: ${boardId} | Delta: ${elapsedMin.toFixed(2)} min`);

            if (!isNaN(elapsedMS) && elapsedMS >= WATCHDOG_TIMEOUT_MS) {
                console.log(`[WATCHDOG] -> Scaduto! Chiusura board ${boardId}`);
                activity.set("is_active", false);
                activity.set("anomaly",   true);
                $app.save(activity);
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});


// ═══════════════════════════════════════════════════════════════
// CRON MEZZANOTTE: split giornaliero
// ═══════════════════════════════════════════════════════════════

cronAdd("midnight_sleep_split", "59 21 * * *", () => { // 21:59 UTC = 23:59 ora italiana (CEST)
    const utils = require(`${__hooks}/utils.js`);
    const SLEEP_TO_ACTIVE_MAP = { d: "i", p: "s", z: "w", a: "v" };
    const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000;

    const italyNowMs  = utils.getItalyTime();
    const italyNow    = new Date(italyNowMs);
    const italyHour   = italyNow.getUTCHours();
    const italyMinute = italyNow.getUTCMinutes();

    if (italyHour !== 23 || italyMinute !== 59) {
        console.log(`[MEZZANOTTE] ora Italia: ${italyHour}:${italyMinute < 10 ? "0" : ""}${italyMinute} — skip`);
        return;
    }

    console.log(`[MEZZANOTTE] ora Italia: 23:59 — avvio split giornaliero`);

    const fineGiornoISO   = new Date(italyNow.getFullYear(), italyNow.getMonth(), italyNow.getDate(), 23, 59, 59).toISOString();
    const inizioGiornoISO = new Date(italyNow.getFullYear(), italyNow.getMonth(), italyNow.getDate() + 1, 0, 0, 0).toISOString();

    try {
        const targetActivities = $app.findRecordsByFilter(
            "activities",
            "is_active = true || (is_active = false && (status = 'd' || status = 'p' || status = 'z' || status = 'a'))",
            "",
            500,
            0
        );
        if (!targetActivities) return;

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
            } catch (err) {
                console.log("Errore board " + boardId + ": " + err);
            }
        });
    } catch (err) {
        console.log("Errore Mezzanotte: " + err);
    }
});