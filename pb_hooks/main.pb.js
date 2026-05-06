// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati — data_sent_raw
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => { // Hook eseguito dopo la creazione di un record nella collection "data_sent_raw"
    const utils = require(`${__hooks}/utils.js`); // Import funzioni helper

    const raw       = e.record; // Record appena inserito
    const imei      = raw.getString("board_id"); // ID dispositivo
    const timestamp = raw.getString("timestamp"); // Timestamp evento
    const sleep     = raw.getBool("sleep"); // Flag sleep
    const trip      = raw.getBool("trip"); // Flag movimento
    const steps     = raw.getInt("steps"); // Numero passi
    const lat       = raw.getFloat("lat"); // Latitudine
    const lon       = raw.getFloat("lon"); // Longitudine
    const hasCoords = !(lat === 0.0 && lon === 0.0); // Verifica coordinate valide

    try {
        const board = utils.getBoardRecord(e.app, imei); // Recupera board associata
        if (!board) {
            console.log(`[DEBUG] ERRORE: Board non trovata per IMEI ${imei}`);
            return;
        }

        console.log(`[DEBUG] Inizio processing pacchetto | BoardID: ${board.id} | Status: Sleep=${sleep}, Trip=${trip}, Steps=${steps}`);

        // ── 1. BATTERIA ──────────────────────────────────────────────────────
        utils.saveBattery( // Salva dati batteria
            e.app,
            board.id,
            timestamp,
            raw.getFloat("battery"),
            raw.getInt("battery_percent"),
            raw.getBool("charging"),
            board
        );

        // ── 2. ACTIVITY: Macchina a Stati ────────────────────────────────────
        let activeActivity = null; // Variabile per activity attiva finale
        
        // 1. Cerca prima se c'è qualcosa di attivo
        const activeList = e.app.findRecordsByFilter(   // SQL Query
            "activities",                               // FROM activities
            "board_id = {:id} && is_active = true",     // WHERE board_id = :id AND is_active = true
            "-end_time",                                // ORDER BY end_time DESC (il "-" indica ordine decrescente)
            1,                                          // LIMIT 1 (prende solo il record più recente)
            0,                                          // OFFSET 0 (nessuno skip)
            { id: board.id }                            // :id = board.id (binding parametro)
        );

        let currentActivity = activeList.length > 0 ? activeList[0] : null; // Prende la più recente

        // 2. LOGICA DI RISVEGLIO: Se non c'è nulla di attivo, guarda l'ultima chiusa
        if (!currentActivity) {
            const recentList = e.app.findRecordsByFilter(
                "activities",
                "board_id = {:id} && is_active = false",
                "-end_time",
                1,
                0,
                { id: board.id }
            );
            const recentClosed = recentList.length > 0 ? recentList[0] : null; // Ultima activity chiusa

            if (recentClosed && utils.SLEEP_STATES.has(recentClosed.getString("status"))) {
                const oldStatus = recentClosed.getString("status"); // Stato precedente
                const wakeStatus = utils.SLEEP_TO_ACTIVE[oldStatus] ?? oldStatus; // Conversione sleep → attivo
                
                console.log(`[DEBUG] Risveglio attività ${recentClosed.id}: ${oldStatus} -> ${wakeStatus}`);
                
                recentClosed.set("is_active", true); // Riattiva
                recentClosed.set("status", wakeStatus); // Aggiorna stato
                e.app.save(recentClosed);
                currentActivity = recentClosed; // Diventa activity corrente
            }
        }

        // 3. Calcolo nuovo stato
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

        if (currentActivity) {
            const rawPrevStatus = currentActivity.getString("status"); // Stato attuale
            const normalizedPrev = utils.SLEEP_TO_ACTIVE[rawPrevStatus] ?? rawPrevStatus; // Normalizzato

            if (sleep) { // Se dispositivo entra in sleep
                const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z"; // Conversione attivo → sleep
                currentActivity.set("is_active", false); // Chiude activity
                currentActivity.set("end_time", timestamp);
                currentActivity.set("status", sleepStatus);
                e.app.save(currentActivity);
                activeActivity = currentActivity;
            } else if (newActiveStatus === normalizedPrev) { // Nessun cambio stato
                currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps); // Aggiorna passi
                currentActivity.set("end_time", timestamp); // Estende activity
                e.app.save(currentActivity);
                activeActivity = currentActivity;
            } else {
                // CAMBIO STATO (es. v → w)
                console.log(`[DEBUG] Transizione stato: ${normalizedPrev} -> ${newActiveStatus}`);
                currentActivity.set("is_active", false); // Chiude activity
                currentActivity.set("end_time", timestamp);
                e.app.save(currentActivity);

                activeActivity = utils.createNewActivity( // Crea nuova activity
                    e.app,
                    board.id,
                    timestamp,
                    newActiveStatus,
                    steps
                );
            }
        } else if (!sleep) { // Nessuna activity attiva e non in sleep
            activeActivity = utils.createNewActivity(
                e.app,
                board.id,
                timestamp,
                newActiveStatus,
                steps
            );
        }

        // ── 3. POSIZIONI ─────────────────────────
        if (hasCoords && activeActivity) { // Salva posizione solo se valida e c'è activity
            try {
                const idAttivita = activeActivity.id; // ID activity

                if (!idAttivita) {
                    console.log("[DEBUG] ERRORE: activeActivity non ha un ID valido!");
                    return;
                }

                const colP = e.app.findCollectionByNameOrId("positions"); // Collection posizioni
                const recP = new Record(colP); // Nuovo record
                
                recP.set("board_id", board.id);
                recP.set("timestamp", timestamp);
                recP.set("lat", lat);
                recP.set("lon", lon);
                
                recP.set("activity", idAttivita); // Relazione con activity
                
                e.app.save(recP);
                console.log(`[DEBUG] OK! Posizione salvata e collegata all'activity: ${idAttivita}`);

            } catch (posErr) {
                console.log(`[DEBUG] FALLIMENTO POSIZIONE: ${posErr.toString()}`);
            }
        }

    } catch (err) {
        console.log("[DEBUG] ERRORE CRITICO HOOK: " + err);
    } finally {
        e.next(); // Continua la pipeline hook
    }
}, "data_sent_raw");


// ═══════════════════════════════════════════════════════════════
// WATCHDOG: chiude attività ferme
// ═══════════════════════════════════════════════════════════════

cronAdd("watchdog_device_silence", "* * * * *", () => { // Ogni minuto
    const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000; // 10 minuti
    const oraAttualeMS = Date.now(); // Timestamp corrente UTC

    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 100, 0);
        
        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const endTimeStr = activity.getString("end_time");

            if (!endTimeStr) return;

            const lastSeenMs = Date.parse(endTimeStr.replace(" ", "T")); // Parsing ISO
            const elapsedMS = oraAttualeMS - lastSeenMs; // Tempo trascorso
            const elapsedMin = elapsedMS / 60000;

            console.log(`[WATCHDOG] Board: ${boardId} | Delta: ${elapsedMin.toFixed(2)} min`);

            if (!isNaN(elapsedMS) && elapsedMS >= WATCHDOG_TIMEOUT_MS) {
                console.log(`[WATCHDOG] -> Scaduto! Chiusura board ${boardId}`);
                activity.set("is_active", false); // Chiude activity
                activity.set("anomaly",   true); // Segna anomalia
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

cronAdd("midnight_sleep_split", "59 21 * * *", () => { // Trigger UTC
    const utils = require(`${__hooks}/utils.js`);
    const SLEEP_TO_ACTIVE_MAP = { d: "i", p: "s", z: "w", a: "v" }; // Mapping stati
    const WATCHDOG_TIMEOUT_MS = 10 * 60 * 1000;

    const italyNowMs   = utils.getItalyTime(); // Timestamp Italia
    const italyNow     = new Date(italyNowMs);
    const italyHour    = italyNow.getUTCHours();
    const italyMinute  = italyNow.getUTCMinutes();

    if (italyHour !== 23 || italyMinute !== 59) { // Sicurezza orario reale
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

        const latestByBoard = {}; // Raggruppamento per board

        targetActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const lastSeenMs = Date.parse(activity.getString("end_time").replace(" ", "T"));

            if (!latestByBoard[boardId] || lastSeenMs > latestByBoard[boardId].lastSeenMs) {
                latestByBoard[boardId] = { activity, lastSeenMs }; // Tiene solo la più recente
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

                if (isActive) { // Se attiva → spezza tra i due giorni
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

                } else if (SLEEP_TO_ACTIVE_MAP[status]) { // Se sleep → conversione
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