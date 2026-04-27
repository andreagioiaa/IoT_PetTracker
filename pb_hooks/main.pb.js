// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati
// ═══════════════════════════════════════════════════════════════
 
onRecordAfterCreateSuccess((e) => {
    const utils = require(`${__hooks}/utils.js`);
 
    const raw          = e.record;
    const boardId      = raw.getString("board_id");
    const timestamp    = raw.getString("timestamp");
    const sleep        = raw.getBool("sleep");
    const steps        = raw.getInt("steps");
    const gpsValid     = raw.getBool("gps_valid");
    const gpsFailCount = raw.getInt("gps_fail_count");
    const netFailCount = raw.getInt("net_fail_count");
    const lat          = raw.getFloat("lat");
    const lon          = raw.getFloat("lon");
 
    console.log(`--- SMISTAMENTO | board: ${boardId} | sleep: ${sleep} ---`);
 
    try {
        // ── 1. BATTERIA ──────────────────────────────────────────────────────
        try {
            const col = e.app.findCollectionByNameOrId("battery_data");
            const rec = new Record(col);
            rec.set("board_id",        boardId);
            rec.set("timestamp",       timestamp);
            rec.set("battery",         raw.getFloat("battery"));
            rec.set("battery_percent", raw.getInt("battery_percent"));
            rec.set("charging",        raw.getBool("charging"));
            e.app.save(rec);
 
            const batteryPercent = raw.getInt("battery_percent");
            if (batteryPercent < 20 && !raw.getBool("charging")) {
                utils.notifyBoardUsers(e.app, boardId, "🔋 Batteria bassa", `Livello: ${batteryPercent}%`);
            }
        } catch (err) {
            console.log("-> battery_data ERRORE: " + err);
        }
 
        // ── 2. POSIZIONI ─────────────────────────────────────────────────────
        // Escludi coordinate 0,0 anche quando gpsValid=true (warm-up GPS)
        const hasCoords = gpsValid && !(lat === 0.0 && lon === 0.0);
        if (hasCoords) {
            try {
                const col = e.app.findCollectionByNameOrId("positions_duplicate");
                const rec = new Record(col);
                rec.set("board_id",  boardId);
                rec.set("timestamp", timestamp);
                rec.set("lon",       lon);
                rec.set("lat",       lat);
                rec.set("geo",       raw.get("geo"));
                rec.set("gps_valid", gpsValid);
                e.app.save(rec);
            } catch (err) {
                console.log("-> positions_duplicate ERRORE: " + err);
            }
        }
 
        // ── 3. ATTIVITÀ ───────────────────────────────────────────────────────
        try {
            let activeActivity = null;
            const active = e.app.findRecordsByFilter(
                "activities", "board_id = {:id} && is_active = true", "-created", 1, 0, { id: boardId }
            );
            if (active.length > 0) activeActivity = active[0];
 
            if (!sleep) {
                // Calcola il nuovo zone status
                const prevStatus = activeActivity ? activeActivity.getString("status") : null;
                const status = hasCoords
                    ? utils.checkGeofences(e.app, boardId, lat, lon, prevStatus)
                    : prevStatus ?? "n";  // Nessuna coordinata → "n" come default
 
                if (activeActivity) {
 
                    if (status === prevStatus) {
                        // ── Stesso status: aggiorna l'activity corrente ──────────
                        activeActivity.set("total_steps", activeActivity.getInt("total_steps") + steps);
                        activeActivity.set("end_time", timestamp);
                        e.app.save(activeActivity);
 
                    } else {
                        // ── Status cambiato: chiudi e apri nuova activity ────────
                        console.log(`[ACTIVITY] status cambiato "${prevStatus}" → "${status}", split activity`);
 
                        activeActivity.set("end_time",  timestamp);
                        activeActivity.set("is_active", false);
                        e.app.save(activeActivity);
 
                        const col = e.app.findCollectionByNameOrId("activities");
                        const rec = new Record(col);
                        rec.set("board_id",    boardId);
                        rec.set("total_steps", steps);
                        rec.set("start_time",  timestamp);
                        rec.set("end_time",    timestamp);
                        rec.set("is_active",   true);
                        rec.set("anomaly",     false);
                        rec.set("status",      status);
                        e.app.save(rec);
                    }
 
                } else {
                    // ── Nessuna activity attiva: valuta se aprirne una nuova ─────
 
                    // Confronto robusto per pacchetti offline/arretrati
                    let tooRecent = false;
                    const recentClosed = e.app.findRecordsByFilter(
                        "activities", "board_id = {:id} && is_active = false", "-created", 1, 0, { id: boardId }
                    );
 
                    if (recentClosed.length > 0) {
                        const closedAtStr = recentClosed[0].getString("end_time");
                        if (closedAtStr) {
                            const closedAt   = new Date(closedAtStr);
                            const packetTime = new Date(timestamp);
                            const diffSec    = (packetTime - closedAt) / 1000;
                            // diffSec negativo = pacchetto arretrato: apri sempre
                            // diffSec positivo e piccolo = dedup normale
                            tooRecent = diffSec >= 0 && diffSec < utils.SESSION_DEDUP_SEC;
                        }
                    }
 
                    if (!tooRecent) {
                        const col = e.app.findCollectionByNameOrId("activities");
                        const rec = new Record(col);
                        rec.set("board_id",    boardId);
                        rec.set("total_steps", steps);
                        rec.set("start_time",  timestamp);
                        rec.set("end_time",    timestamp);
                        rec.set("is_active",   true);
                        rec.set("anomaly",     false);
                        rec.set("status",      status);
                        e.app.save(rec);
                    }
                }
 
            } else if (activeActivity) {
                // ── Sleep: chiudi l'activity corrente con status finale ──────────
                const prevStatus2 = activeActivity.getString("status");
                const sleepStatus = utils.toSleepStatus(prevStatus2);
 
                if (sleepStatus !== prevStatus2) {
                    // Solo aggiorna se lo status cambia effettivamente
                    activeActivity.set("status", sleepStatus);
                }
 
                activeActivity.set("end_time",  timestamp);
                activeActivity.set("is_active", false);
                e.app.save(activeActivity);
 
                console.log(`[ACTIVITY] sleep: "${prevStatus2}" → "${sleepStatus}"`);
            }
 
        } catch (err) {
            console.log("-> activities ERRORE: " + err);
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
 
    const record   = e.record;
    const boardId  = record.getString("board_id");
    const status   = record.getString("status");
    const isActive = record.getBool("is_active");
 
    // Reagisce solo alle activity attive appena aperte
    if (!isActive) {
        e.next();
        return;
    }
 
    console.log(`[ACTIVITY HOOK] board: ${boardId} | status: ${status}`);
 
    try {
        switch (status) {
            case "s":
                // Search: animale fuori zona con alarm ON
                // La notifica push è già inviata da checkGeofences()
                utils.salvaEvento(e.app, boardId, "status_search", "Animale uscito dalla zona — ricerca attiva");
                break;
 
            case "i":
                // Inside: animale rientrato nella geofence
                utils.salvaEvento(e.app, boardId, "status_inside", "Animale rientrato nella zona");
                break;
 
            case "f":
                // Find: animale fuori zona ma alarm disattivato (trovato manualmente)
                utils.salvaEvento(e.app, boardId, "status_find", "Animale trovato — alarm disattivato");
                break;
 
            case "w":
                // Walk: passeggiata normale, nessun alarm
                utils.salvaEvento(e.app, boardId, "status_walk", "Animale in passeggiata");
                break;
 
            case "n":
                // No geofence: nessuna zona configurata per questa board
                utils.salvaEvento(e.app, boardId, "status_no_geofence", "Nessuna geofence attiva configurata");
                break;
 
            default:
                console.log(`[ACTIVITY HOOK] Status non gestito: "${status}"`);
        }
    } catch (err) {
        console.log("[ACTIVITY HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
 
}, "activities");
 
 
// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog Inattività
// ═══════════════════════════════════════════════════════════════
 
cronAdd("watchdog_device_silence", "* * * * *", () => {
    const utils = require(`${__hooks}/utils.js`);
    const TIMEOUT_MS = utils.WATCHDOG_TIMEOUT_MIN * 60 * 1000;
    const now = new Date();
 
    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 0, 0);
        if (!activeActivities || activeActivities.length === 0) return;
 
        activeActivities.forEach(activity => {
            const boardId = activity.getString("board_id");
 
            // Salta activity con end_time null o invalido
            const endTimeStr = activity.getString("end_time");
            if (!endTimeStr) {
                console.log(`[WATCHDOG] board ${boardId}: end_time nullo, skip`);
                return;
            }
 
            const endTime = new Date(endTimeStr);
            // Ignora date chiaramente invalide (es. epoch 1970)
            if (endTime.getFullYear() < 2000) {
                console.log(`[WATCHDOG] board ${boardId}: end_time invalido (${endTimeStr}), skip`);
                return;
            }
 
            const elapsed = now - endTime;
 
            if (elapsed >= TIMEOUT_MS) {
                activity.set("is_active", false);
                activity.set("end_time",  now.toISOString());
                activity.set("anomaly",   true);
                $app.save(activity);
 
                utils.salvaEvento(
                    $app, boardId,
                    "watchdog",
                    `Chiusura per inattività (${Math.round(elapsed / 60000)} min)`
                );
 
                console.log(`[WATCHDOG] board ${boardId}: activity chiusa per inattività`);
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});