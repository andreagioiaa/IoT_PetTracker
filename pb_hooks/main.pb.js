// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati
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

    console.log(`--- SMISTAMENTO | board: ${boardId} | sleep: ${sleep} | trip: ${trip} ---`);

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
        // activeActivity viene mantenuto anche dopo la chiusura per consentire
        // il salvataggio della posizione GPS con il riferimento corretto.
        let activeActivity = null;
        try {
            const active = e.app.findRecordsByFilter(
                "activities", "board_id = {:id} && is_active = true", "-id", 1, 0, { id: boardId }
            );
            if (active.length > 0) activeActivity = active[0];

            if (!sleep) {
                // ── CASO SVEGLIO ─────────────────────────────────────────────
                const prevStatus = activeActivity ? activeActivity.getString("status") : null;

                // Il calcolo del nuovo status avviene sempre se:
                //   - ci sono coordinate valide, OPPURE
                //   - il pacchetto è un trip (non servono coordinate GPS)
                const status = (hasCoords || trip)
                    ? utils.checkGeofences(e.app, boardId, lat, lon, prevStatus, trip)
                    : prevStatus ?? "n";

                if (activeActivity) {
                    if (status === prevStatus) {
                        // Stesso stato: aggiorniamo la sessione esistente
                        activeActivity.set("total_steps", activeActivity.getInt("total_steps") + steps);
                        activeActivity.set("end_time", timestamp);
                        e.app.save(activeActivity);
                    } else {
                        // Cambio di stato: chiudiamo la sessione corrente e ne apriamo una nuova
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
                        activeActivity = recA; // ← puntiamo alla nuova sessione
                    }
                } else {
                    // Nessuna sessione attiva: controlla dedup su sessioni chiuse di recente
                    const recentClosed = e.app.findRecordsByFilter(
                        "activities", "board_id = {:id} && is_active = false", "-id", 1, 0, { id: boardId }
                    );

                    if (recentClosed.length > 0) {
                        const closedAtStr  = recentClosed[0].getString("end_time");
                        const closedStatus = recentClosed[0].getString("status");
                        const diffSec      = (new Date(timestamp) - new Date(closedAtStr)) / 1000;

                        // Riattiva solo se:
                        //   - è passato poco tempo (< SESSION_DEDUP_SEC)
                        //   - lo status è lo stesso, OPPURE è una transizione trip-sleep→trip (a→v)
                        const sameOrCompatible = closedStatus === status
                            || (closedStatus === "a" && status === "v");

                        if (diffSec >= 0 && diffSec < utils.SESSION_DEDUP_SEC && sameOrCompatible) {
                            activeActivity = recentClosed[0];
                            activeActivity.set("is_active", true);
                            activeActivity.set("end_time",  timestamp);
                            e.app.save(activeActivity);
                            console.log(`[DEBUG] Sessione riattivata (dedup, ${diffSec.toFixed(1)}s, ${closedStatus}→${status})`);
                        }
                    }

                    // Se dopo il dedup non c'è ancora una sessione attiva, ne creiamo una nuova
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

            } else {
                // ── CASO SLEEP ───────────────────────────────────────────────
                if (activeActivity) {
                    const prevStatus = activeActivity.getString("status");

                    if (prevStatus === "v") {
                        // Caso speciale: sleep durante viaggio.
                        // Non chiudiamo la sessione, ma cambiamo lo status in "a" (trip-sleep).
                        // La sessione rimane is_active=true per continuare a ricevere posizioni GPS.
                        activeActivity.set("status",   "a");
                        activeActivity.set("end_time", timestamp);
                        e.app.save(activeActivity);
                        console.log(`[SLEEP+TRIP] board=${boardId} entrata in sleep durante viaggio → status "a"`);
                        // activeActivity è ancora valida: la posizione GPS verrà collegata correttamente
                    } else {
                        // Chiusura normale della sessione per sleep
                        activeActivity.set("is_active", false);
                        activeActivity.set("end_time",  timestamp);
                        e.app.save(activeActivity);
                        // NOTA: NON azzeriamo activeActivity qui, così la posizione GPS
                        // (sezione 3) viene comunque salvata con il riferimento alla sessione chiusa
                    }
                }
            }
        } catch (err) { console.log("-> activities ERRORE: " + err); }

        // ── 3. POSIZIONI ─────────────────────────────────────────────────────
        // Salviamo la posizione sempre se le coordinate sono valide.
        // activeActivity è valorizzata in tutti i casi (sleep o no) grazie alla logica sopra.
        if (hasCoords) {
            try {
                const colP = e.app.findCollectionByNameOrId("positions_duplicate");
                const recP = new Record(colP);
                recP.set("board_id",  boardId);
                recP.set("timestamp", timestamp);
                recP.set("lon",       lon);
                recP.set("lat",       lat);

                if (activeActivity) {
                    recP.set("activity", activeActivity.getString("id"));
                }

                e.app.save(recP);
                console.log(`[SUCCESS] Posizione salvata | activity: ${activeActivity ? activeActivity.getString("id") : 'NULL'}`);
            } catch (err) { console.log("-> positions_duplicate ERRORE: " + err); }
        }

    } catch (globalErr) {
        console.log("--- ERRORE CRITICO MAIN ---: " + globalErr);
    } finally {
        e.next();
    }
}, "data_sent_raw");

// ═══════════════════════════════════════════════════════════════
//  HOOK: Reazione cambio status su activities (onCreate)
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);
    const record   = e.record;
    const boardId  = record.getString("board_id");
    const status   = record.getString("status");
    const isActive = record.getBool("is_active");

    if (!isActive) {
        e.next();
        return;
    }

    try {
        switch (status) {
            case "s": utils.salvaEvento(e.app, boardId, "status_search",      "Animale fuori zona — ricerca attiva"); break;
            case "i": utils.salvaEvento(e.app, boardId, "status_inside",      "Animale rientrato nella zona"); break;
            case "f": utils.salvaEvento(e.app, boardId, "status_find",        "Animale trovato"); break;
            case "w": utils.salvaEvento(e.app, boardId, "status_walk",        "Animale in passeggiata"); break;
            case "n": utils.salvaEvento(e.app, boardId, "status_no_geofence", "Nessuna geofence configurata"); break;
            case "v": utils.salvaEvento(e.app, boardId, "status_trip",        "Animale in viaggio su veicolo"); break;
            case "a": utils.salvaEvento(e.app, boardId, "status_trip_sleep",  "Animale in sleep durante il viaggio"); break;
        }
    } catch (err) {
        console.log("[ACTIVITY HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");

// ═══════════════════════════════════════════════════════════════
//  HOOK: Reazione aggiornamento status su activities (onUpdate)
//  Gestisce le transizioni:
//    "v" → "a"  (sleep durante viaggio)
//    "a" → "v"  (risveglio ancora in viaggio)
// ═══════════════════════════════════════════════════════════════

onRecordAfterUpdateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);
    const record   = e.record;
    const boardId  = record.getString("board_id");
    const status   = record.getString("status");
    const isActive = record.getBool("is_active");

    if (!isActive) {
        e.next();
        return;
    }

    try {
        switch (status) {
            case "v": utils.salvaEvento(e.app, boardId, "status_trip",       "Animale in viaggio su veicolo"); break;
            case "a": utils.salvaEvento(e.app, boardId, "status_trip_sleep", "Animale in sleep durante il viaggio"); break;
        }
    } catch (err) {
        console.log("[ACTIVITY UPDATE HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");

// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog Inattività (Chiude sessioni appese)
// ═══════════════════════════════════════════════════════════════

cronAdd("watchdog_device_silence", "* * * * *", () => {
    const utils      = require(`${__hooks}/utils.js`);
    const TIMEOUT_MS = utils.WATCHDOG_TIMEOUT_MIN * 60 * 1000;
    const now        = new Date();

    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 0, 0);
        if (!activeActivities) return;

        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const endTimeStr = activity.getString("end_time");
            if (!endTimeStr) return;

            const elapsed = now - new Date(endTimeStr);
            if (elapsed >= TIMEOUT_MS) {
                activity.set("is_active", false);
                activity.set("end_time",  now.toISOString());
                activity.set("anomaly",   true);
                $app.save(activity);
                utils.salvaEvento($app, boardId, "watchdog", `Chiusura automatica per inattività`);
                console.log(`[WATCHDOG] Sessione board ${boardId} chiusa per inattività`);
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});