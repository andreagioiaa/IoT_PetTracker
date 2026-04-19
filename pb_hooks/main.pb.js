// ═══════════════════════════════════════════════════════════════
//  CONFIGURAZIONE
// ═══════════════════════════════════════════════════════════════
const WATCHDOG_TIMEOUT_MIN  = 10; // Minuti di silenzio prima che il watchdog intervenga
const GPS_FAIL_ALERT_THRESH = 3;  // Numero di pacchetti consecutivi senza GPS prima di loggare

// ───────────────────────────────────────────────────────────────
// Salva un evento di anomalia nella collection "device_events"
// Campi richiesti: board_id (text), type (text), detail (text), timestamp (text)
// ───────────────────────────────────────────────────────────────
function salvaEvento(app, boardId, type, detail) {
    try {
        const col = app.findCollectionByNameOrId("device_events");
        const rec = new Record(col);
        rec.set("board_id", boardId);
        rec.set("type", type);
        rec.set("detail", detail);
        rec.set("timestamp", new Date().toISOString());
        app.save(rec);
        console.log("[EVENTI] Salvato evento '" + type + "' per board " + boardId);
    } catch (err) {
        console.log("[EVENTI] Errore salvataggio evento '" + type + "': " + err);
    }
}

// ═══════════════════════════════════════════════════════════════
//  HOOK: onRecordAfterCreateSuccess → data_sent_raw
// ═══════════════════════════════════════════════════════════════
onRecordAfterCreateSuccess((e) => {
    const raw          = e.record;
    const boardId      = raw.getString("board_id");
    const timestamp    = raw.getString("timestamp");
    const sleep        = raw.getBool("sleep");
    const steps        = raw.getInt("steps");
    const gpsValid     = raw.getBool("gps_valid");
    const gpsFailCount = raw.getInt("gps_fail_count");
    const netFailCount = raw.getInt("net_fail_count");

    console.log("--- SMISTAMENTO AVVIATO PER BOARD: " + boardId + " | sleep: " + sleep + " | steps: " + steps + " | gps_valid: " + gpsValid + " | gps_fail: " + gpsFailCount + " | net_fail: " + netFailCount + " ---");

    // 1. SMISTAMENTO BATTERIA
    try {
        const batteryCollection = e.app.findCollectionByNameOrId("battery_data");
        const batteryRecord = new Record(batteryCollection);
        batteryRecord.set("board_id", boardId);
        batteryRecord.set("timestamp", timestamp);
        batteryRecord.set("battery", raw.getFloat("battery"));
        batteryRecord.set("battery_percent", raw.getInt("battery_percent"));
        batteryRecord.set("charging", raw.getBool("charging"));
        e.app.save(batteryRecord);
        console.log("-> battery_data: OK");
    } catch (err) {
        console.log("-> battery_data: ERRORE: " + err);
    }

    // 2. SMISTAMENTO POSIZIONI
    // Salta il salvataggio se non abbiamo mai avuto un fix (lat e lon entrambi 0)
    const lat = raw.getFloat("lat");
    const lon = raw.getFloat("lon");
    const hasCoords = !(lat === 0.0 && lon === 0.0 && !gpsValid);

    if (hasCoords) {
        try {
            const positionsCollection = e.app.findCollectionByNameOrId("positions_duplicate");
            const positionsRecord = new Record(positionsCollection);
            positionsRecord.set("board_id", boardId);
            positionsRecord.set("timestamp", timestamp);
            positionsRecord.set("lon", lon);
            positionsRecord.set("lat", lat);
            positionsRecord.set("geo", raw.get("geo"));
            positionsRecord.set("gps_valid", gpsValid);
            e.app.save(positionsRecord);
            console.log("-> positions_duplicate: OK (gps_valid=" + gpsValid + ")");
        } catch (err) {
            console.log("-> positions_duplicate: ERRORE: " + err);
        }
    } else {
        console.log("-> positions_duplicate: SKIP (nessuna coordinata disponibile)");
    }

    // 3. SMISTAMENTO ACTIVITIES
    try {
        let activeActivity = null;
        try {
            activeActivity = e.app.findFirstRecordByFilter(
                "activities",
                "board_id = {:boardId} && is_active = true",
                { "boardId": boardId }
            );
        } catch (_) {
            // Nessuna activity attiva trovata, activeActivity resta null
        }

        if (!sleep) {
            // Dispositivo SVEGLIO → sessione attiva
            if (activeActivity) {
                const currentSteps = activeActivity.getInt("total_steps");
                activeActivity.set("total_steps", currentSteps + steps);
                activeActivity.set("end_time", timestamp);
                e.app.save(activeActivity);
                console.log("-> activities UPDATE (steps: " + (currentSteps + steps) + "): OK");
            } else {
                const activitiesCollection = e.app.findCollectionByNameOrId("activities");
                const activitiesRecord = new Record(activitiesCollection);
                activitiesRecord.set("board_id", boardId);
                activitiesRecord.set("total_steps", steps);
                activitiesRecord.set("start_time", timestamp);
                activitiesRecord.set("end_time", timestamp);
                activitiesRecord.set("is_active", true);
                activitiesRecord.set("anomaly", false);
                e.app.save(activitiesRecord);
                console.log("-> activities CREATE nuova sessione: OK");
            }
        } else {
            // Dispositivo in SLEEP → chiudi sessione
            if (activeActivity) {
                activeActivity.set("end_time", timestamp);
                activeActivity.set("is_active", false);
                e.app.save(activeActivity);
                console.log("-> activities CHIUSURA sessione: OK");
            } else {
                console.log("-> activities: sleep=true ma nessuna sessione attiva trovata, nulla da fare");
            }
        }
    } catch (err) {
        console.log("-> activities: ERRORE: " + err);
    }

    // 4. LOG: Rete ripristinata dopo boot senza segnale
    if (netFailCount > 0) {
        console.log("-> [LOG] Rete ripristinata dopo " + netFailCount + " boot senza segnale.");
        salvaEvento(e.app, boardId, "net_restored", "Irraggiungibile per " + netFailCount + " boot consecutivi");
    }

    // 5. LOG: GPS assente per troppi pacchetti di fila
    // Scatta solo al raggiungimento esatto della soglia, non ad ogni pacchetto successivo
    if (!gpsValid && gpsFailCount === GPS_FAIL_ALERT_THRESH) {
        console.log("-> [LOG] GPS assente da " + gpsFailCount + " pacchetti consecutivi.");
        salvaEvento(e.app, boardId, "gps_lost", "Nessun fix GPS per " + gpsFailCount + " pacchetti consecutivi");
    }

    // 6. LOG: GPS tornato disponibile dopo un'assenza
    if (gpsValid && gpsFailCount === 0) {
        try {
            const prevPkt = e.app.findFirstRecordByFilter(
                "data_sent_raw",
                "board_id = {:boardId} && id != {:id}",
                { "boardId": boardId, "id": raw.getId() },
                "-created"
            );
            if (prevPkt && !prevPkt.getBool("gps_valid")) {
                console.log("-> [LOG] GPS ripristinato per board " + boardId);
                salvaEvento(e.app, boardId, "gps_restored", "Fix GPS tornato disponibile");
            }
        } catch (_) {}
    }

    e.next();

}, "data_sent_raw");


// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog silenzio dispositivo
//  Ogni minuto controlla se una sessione attiva è ferma da troppo
// ═══════════════════════════════════════════════════════════════
cronAdd("watchdog_device_silence", "* * * * *", () => {
    const TIMEOUT_MS = WATCHDOG_TIMEOUT_MIN * 60 * 1000;
    const now = new Date();

    try {
        const activeActivities = $app.findRecordsByFilter(
            "activities",
            "is_active = true",
            "", 0, 0
        );

        if (!activeActivities || activeActivities.length === 0) return;

        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const endTime    = new Date(activity.getString("end_time"));
            const elapsed    = now - endTime;
            const elapsedMin = Math.round(elapsed / 60000);

            if (elapsed < TIMEOUT_MS) return; // Tutto ok, dispositivo attivo

            console.log("[WATCHDOG] " + boardId + " silenziosa da " + elapsedMin + " min. Chiusura sessione.");

            // Chiudi la sessione segnandola come anomalia
            try {
                activity.set("is_active", false);
                activity.set("end_time", now.toISOString());
                activity.set("anomaly", true);
                $app.save(activity);
                console.log("[WATCHDOG] Sessione chiusa come anomalia.");
            } catch (saveErr) {
                console.log("[WATCHDOG] Errore chiusura sessione: " + saveErr);
            }

            salvaEvento($app, boardId, "watchdog", "Nessun pacchetto da " + elapsedMin + " minuti");
        });

    } catch (err) {
        console.log("[WATCHDOG] Errore generale: " + err);
    }
});