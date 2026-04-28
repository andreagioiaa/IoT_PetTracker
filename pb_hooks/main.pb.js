// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);

    const raw       = e.record;
    const boardId   = raw.getString("board_id");
    const timestamp = raw.getString("timestamp");
    const sleep     = raw.getBool("sleep");
    const steps     = raw.getInt("steps");
    //const gpsValid  = raw.getBool("gps_valid");
    const lat       = raw.getFloat("lat");
    const lon       = raw.getFloat("lon");

    //const hasCoords = gpsValid && !(lat === 0.0 && lon === 0.0);
    const hasCoords = !(lat === 0.0 && lon === 0.0);

    console.log(`--- SMISTAMENTO | board: ${boardId} | sleep: ${sleep} ---`);

    try {
        // ── 1. BATTERIA ──────────────────────────────────────────────────────
        try {
            const batteryPercent = raw.getInt("battery_percent");
            const isCharging     = raw.getBool("charging");

            const colB = e.app.findCollectionByNameOrId("battery_data");
            const recB = new Record(colB);
            recB.set("board_id",        boardId);
            recB.set("timestamp",       timestamp);
            recB.set("battery",         raw.getFloat("battery"));
            recB.set("battery_percent", batteryPercent);
            recB.set("charging",        isCharging);
            e.app.save(recB);

            utils.checkBatteryNotify(e.app, boardId, batteryPercent, isCharging);
        } catch (err) { console.log("-> battery_data ERRORE: " + err); }

        // ── 2. ATTIVITÀ ───────────────────────────────────────────────────────
        let activeActivity = null;
        try {
            const active = e.app.findRecordsByFilter(
                "activities", "board_id = {:id} && is_active = true", "-id", 1, 0, { id: boardId }
            );
            if (active.length > 0) activeActivity = active[0];

            if (!sleep) {
                const prevStatus = activeActivity ? activeActivity.getString("status") : null;
                const status = hasCoords
                    ? utils.checkGeofences(e.app, boardId, lat, lon, prevStatus)
                    : prevStatus ?? "n";

                if (activeActivity) {
                    // Se c'è già una sessione attiva, la aggiorniamo
                    if (status === prevStatus) {
                        activeActivity.set("total_steps", activeActivity.getInt("total_steps") + steps);
                        activeActivity.set("end_time", timestamp);
                        e.app.save(activeActivity);
                    } else {
                        // Se cambia lo stato, chiudiamo questa e ne apriamo una nuova
                        activeActivity.set("end_time",  timestamp);
                        activeActivity.set("is_active", false);
                        e.app.save(activeActivity);

                        const colA = e.app.findCollectionByNameOrId("activities");
                        const recA = new Record(colA);
                        recA.set("board_id",    boardId);
                        recA.set("start_time",  timestamp);
                        recA.set("is_active",   true);
                        recA.set("status",      status);
                        e.app.save(recA);
                        activeActivity = recA;
                    }
                } else {
                    // SE NON C'È ATTIVITÀ ATTIVA: Controlliamo se ce n'è una chiusa da poco
                    const recentClosed = e.app.findRecordsByFilter(
                        "activities", "board_id = {:id} && is_active = false", "-id", 1, 0, { id: boardId }
                    );

                    if (recentClosed.length > 0) {
                        const closedAtStr = recentClosed[0].getString("end_time");
                        const diffSec = (new Date(timestamp) - new Date(closedAtStr)) / 1000;

                        // Se è passata meno di SESSION_DEDUP_SEC (30s), RIATTIVIAMO quella vecchia
                        if (diffSec >= 0 && diffSec < utils.SESSION_DEDUP_SEC) {
                            activeActivity = recentClosed[0];
                            activeActivity.set("is_active", true);
                            activeActivity.set("end_time", timestamp);
                            e.app.save(activeActivity);
                            console.log(`[DEBUG] Sessione riattivata per evitare N/A`);
                        }
                    }

                    // Se dopo il controllo sopra è ancora null, ne creiamo una nuova
                    if (!activeActivity) {
                        const colA = e.app.findCollectionByNameOrId("activities");
                        const recA = new Record(colA);
                        recA.set("board_id",    boardId);
                        recA.set("start_time",  timestamp);
                        recA.set("is_active",   true);
                        recA.set("status",      status);
                        e.app.save(recA);
                        activeActivity = recA;
                    }
                }
            } else if (activeActivity) {
                // Gestione Sleep (chiusura)
                activeActivity.set("is_active", false);
                activeActivity.set("end_time",  timestamp);
                e.app.save(activeActivity);
                // NOTA: NON settare activeActivity = null qui, altrimenti perdi il punto GPS dello sleep
            }
        } catch (err) { console.log("-> activities ERRORE: " + err); }

        // ── 3. POSIZIONI (Ora activeActivity NON è più null) ──────────────────
        if (hasCoords) {
            try {
                const colP = e.app.findCollectionByNameOrId("positions_duplicate");
                const recP = new Record(colP);
                recP.set("board_id",  boardId);
                recP.set("timestamp", timestamp);
                recP.set("lon",       lon);
                recP.set("lat",       lat);
                //recP.set("gps_valid", gpsValid);

                if (activeActivity) {
                    recP.set("activity", activeActivity.getId());
                }

                e.app.save(recP);
                console.log(`[SUCCESS] Posizione salvata con attività: ${activeActivity ? activeActivity.getId() : 'NULL'}`);
            } catch (err) { console.log("-> positions_duplicate ERRORE: " + err); }
        }

    } catch (globalErr) {
        console.log("--- ERRORE CRITICO MAIN ---: " + globalErr);
    } finally {
        e.next();
    }
}, "data_sent_raw");

// ═══════════════════════════════════════════════════════════════
//  HOOK: Reazione cambio status su activities
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);
    const record = e.record;
    const boardId = record.getString("board_id");
    const status = record.getString("status");
    const isActive = record.getBool("is_active");

    if (!isActive) {
        e.next();
        return;
    }

    try {
        switch (status) {
            case "s": utils.salvaEvento(e.app, boardId, "status_search", "Animale fuori zona — ricerca attiva"); break;
            case "i": utils.salvaEvento(e.app, boardId, "status_inside", "Animale rientrato nella zona"); break;
            case "f": utils.salvaEvento(e.app, boardId, "status_find", "Animale trovato"); break;
            case "w": utils.salvaEvento(e.app, boardId, "status_walk", "Animale in passeggiata"); break;
            case "n": utils.salvaEvento(e.app, boardId, "status_no_geofence", "Nessuna geofence configurata"); break;
        }
    } catch (err) {
        console.log("[ACTIVITY HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");

// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog Inattività (Chiude sessioni appese)
// ═══════════════════════════════════════════════════════════════

cronAdd("watchdog_device_silence", "* * * * *", () => {
    const utils = require(`${__hooks}/utils.js`);
    const TIMEOUT_MS = utils.WATCHDOG_TIMEOUT_MIN * 60 * 1000;
    const now = new Date();

    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 0, 0);
        if (!activeActivities) return;

        activeActivities.forEach(activity => {
            const boardId = activity.getString("board_id");
            const endTimeStr = activity.getString("end_time");
            if (!endTimeStr) return;

            const elapsed = now - new Date(endTimeStr);
            if (elapsed >= TIMEOUT_MS) {
                activity.set("is_active", false);
                activity.set("end_time", now.toISOString());
                activity.set("anomaly", true);
                $app.save(activity);
                utils.salvaEvento($app, boardId, "watchdog", `Chiusura automatica per inattività`);
                console.log(`[WATCHDOG] Sessione board ${boardId} chiusa per inattività`);
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});