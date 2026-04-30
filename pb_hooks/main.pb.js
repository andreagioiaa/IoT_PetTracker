// ═══════════════════════════════════════════════════════════════
//  HOOK PRINCIPALE: Smistamento dati — data_sent_raw
// ═══════════════════════════════════════════════════════════════
//
//  STATI ATTIVI  : i (inside), v (trip), s (search), w (walk)
//  STATI SLEEP   : d (←i), a (←v), p (←s), z (←w)
//
//  PRIORITÀ STATUS: trip → inside → alarm
//
//  LOGICA SLEEP:
//    - sleep=true && era "v" && steps==0  → rimane "v" (trip-sleep, status "a")
//    - sleep=true && altri stati           → chiude activity, salva stato sleep
//    - sleep=false                         → ricalcola status attivo
//
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

    console.log(`--- SMISTAMENTO | board:${boardId} | sleep:${sleep} | trip:${trip} | steps:${steps} ---`);

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

        // ── 2. ACTIVITY ──────────────────────────────────────────────────────
        // Strategia di ricerca:
        //   1. Prima cerca un'activity is_active=true (stato attivo o trip-sleep "a")
        //   2. Se non trovata, cerca l'ultima chiusa (is_active=false) — potrebbe
        //      essere un risveglio da sleep (d/p/z) o un dedup per micro-gap
        //
        // CASISTICHE:
        //   A. Stesso stato, sveglio          → aggiorna end_time + steps
        //   B. Sleep, stesso stato             → is_active=false, status→sleep
        //   C. Sleep, trip                     → is_active=true, status→"a"
        //   D. Sveglio, era in sleep, uguale   → riattiva stessa activity (no nuova)
        //   E. Sveglio, era in sleep, diverso  → chiudi con stato attivo, apri nuova
        //   F. Sveglio, stato diverso attivo   → chiudi vecchia, apri nuova
        let activeActivity = null;

        try {
            // ── Cerca activity corrente: prima attiva, poi ultima chiusa ─────
            const activeList = e.app.findRecordsByFilter(
                "activities", "board_id = {:id} && is_active = true", "-id", 1, 0, { id: boardId }
            );
            let currentActivity   = activeList.length > 0 ? activeList[0] : null;
            let currentIsFromSleep = false; // flag: currentActivity proviene da sessione sleep chiusa

            if (!currentActivity) {
                // Nessuna attiva: cerca l'ultima chiusa (potrebbe essere sleep o dedup)
                const closedList = e.app.findRecordsByFilter(
                    "activities", "board_id = {:id} && is_active = false", "-end_time", 1, 0, { id: boardId }
                );
                if (closedList.length > 0) {
                    currentActivity    = closedList[0];
                    currentIsFromSleep = true;
                }
            }

            const prevStatus     = currentActivity ? currentActivity.getString("status") : null;
            const isCurSleep     = prevStatus ? utils.SLEEP_STATES.has(prevStatus) : false;
            const curActiveStatus = (prevStatus && isCurSleep)
                ? (utils.SLEEP_TO_ACTIVE[prevStatus] ?? prevStatus)
                : prevStatus;

            // Calcola nuovo status attivo (priorità: trip → inside → alarm)
            const newActiveStatus = utils.computeStatus(
                e.app, boardId, lat, lon, trip, steps, prevStatus
            );

            console.log(`[STATUS] prev="${prevStatus}" curActive="${curActiveStatus}" new="${newActiveStatus}" sleep=${sleep} fromSleep=${currentIsFromSleep}`);

            // ════════════════════════════════════════════════════════════════
            // CASO SLEEP
            // ════════════════════════════════════════════════════════════════
            if (sleep) {
                const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z";
                const isTripSleep = newActiveStatus === "v";

                if (currentActivity && !currentIsFromSleep) {
                    // Activity attiva presente
                    if (isTripSleep) {
                        // CASO C: trip-sleep → rimane is_active=true con status "a"
                        if (prevStatus !== "a") {
                            currentActivity.set("status",   "a");
                            currentActivity.set("end_time", timestamp);
                            e.app.save(currentActivity);
                            console.log(`[SLEEP+TRIP] board=${boardId} status → "a"`);
                        } else {
                            currentActivity.set("end_time", timestamp);
                            e.app.save(currentActivity);
                        }
                        activeActivity = currentActivity;
                    } else {
                        // CASO B: sleep normale → chiudi con status sleep
                        currentActivity.set("is_active", false);
                        currentActivity.set("end_time",  timestamp);
                        currentActivity.set("status",    sleepStatus);
                        e.app.save(currentActivity);
                        activeActivity = currentActivity; // mantieni ref per posizioni
                        console.log(`[SLEEP] board=${boardId} chiusa | status="${sleepStatus}"`);
                    }
                } else {
                    // Nessuna activity attiva: in sleep non creiamo nulla
                    console.log(`[SLEEP] board=${boardId} nessuna activity attiva, skip`);
                }

            // ════════════════════════════════════════════════════════════════
            // CASO SVEGLIO
            // ════════════════════════════════════════════════════════════════
            } else {
                if (currentActivity && !currentIsFromSleep) {
                    // ── Activity attiva trovata ───────────────────────────────
                    if (newActiveStatus === curActiveStatus) {
                        // CASO A: stesso stato (o risveglio trip-sleep "a"→"v")
                        currentActivity.set("status",      newActiveStatus);
                        currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
                        currentActivity.set("end_time",    timestamp);
                        e.app.save(currentActivity);
                        activeActivity = currentActivity;
                        console.log(`[AGGIORNA] board=${boardId} status="${newActiveStatus}" end_time aggiornato`);
                    } else {
                        // CASO F: cambio stato attivo→attivo → chiudi e apri nuova
                        currentActivity.set("is_active", false);
                        currentActivity.set("end_time",  timestamp);
                        e.app.save(currentActivity);

                        const colA = e.app.findCollectionByNameOrId("activities");
                        const recA = new Record(colA);
                        recA.set("board_id",    boardId);
                        recA.set("start_time",  timestamp);
                        recA.set("end_time",    timestamp);
                        recA.set("is_active",   true);
                        recA.set("status",      newActiveStatus);
                        recA.set("total_steps", steps);
                        e.app.save(recA);
                        activeActivity = recA;
                        console.log(`[CAMBIO] board=${boardId} "${prevStatus}" → "${newActiveStatus}"`);
                    }

                } else if (currentActivity && currentIsFromSleep) {
                    // ── Ultima activity è chiusa (sleep o micro-gap) ──────────
                    const closedAtStr = currentActivity.getString("end_time");
                    const endTimeNorm = closedAtStr.replace(" ", "T");
                    const diffSec     = (new Date(timestamp) - new Date(endTimeNorm)) / 1000;

                    const isSameState = curActiveStatus === newActiveStatus
                        || (prevStatus === "a" && newActiveStatus === "v"); // risveglio trip-sleep

                    if (isCurSleep && isSameState) {
                        // CASO D: risveglio dallo stesso stato → riattiva stessa activity
                        currentActivity.set("is_active",   true);
                        currentActivity.set("status",      newActiveStatus);
                        currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
                        currentActivity.set("end_time",    timestamp);
                        e.app.save(currentActivity);
                        activeActivity = currentActivity;
                        console.log(`[RISVEGLIO] board=${boardId} riattivata "${prevStatus}" → "${newActiveStatus}"`);

                    } else if (isCurSleep && !isSameState) {
                        // CASO E: risveglio con cambio stato
                        // Chiudi la sessione sleep con il suo stato attivo (non sleep)
                        currentActivity.set("status",   curActiveStatus);
                        currentActivity.set("end_time", timestamp);
                        e.app.save(currentActivity);

                        // Apri nuova sessione con il nuovo stato attivo
                        const colA = e.app.findCollectionByNameOrId("activities");
                        const recA = new Record(colA);
                        recA.set("board_id",    boardId);
                        recA.set("start_time",  timestamp);
                        recA.set("end_time",    timestamp);
                        recA.set("is_active",   true);
                        recA.set("status",      newActiveStatus);
                        recA.set("total_steps", steps);
                        e.app.save(recA);
                        activeActivity = recA;
                        console.log(`[RISVEGLIO+CAMBIO] board=${boardId} "${prevStatus}"→"${curActiveStatus}" chiusa, nuova "${newActiveStatus}"`);

                    } else if (!isCurSleep && !isNaN(diffSec) && diffSec >= 0 && diffSec < utils.SESSION_DEDUP_SEC && isSameState) {
                        // CASO dedup: micro-gap su sessione non-sleep → riattiva
                        currentActivity.set("is_active",   true);
                        currentActivity.set("status",      newActiveStatus);
                        currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
                        currentActivity.set("end_time",    timestamp);
                        e.app.save(currentActivity);
                        activeActivity = currentActivity;
                        console.log(`[DEDUP] board=${boardId} riattivata (${diffSec.toFixed(1)}s, "${prevStatus}"→"${newActiveStatus}")`);

                    } else {
                        // Nessuna riattivazione possibile: crea nuova sessione
                        const colA = e.app.findCollectionByNameOrId("activities");
                        const recA = new Record(colA);
                        recA.set("board_id",    boardId);
                        recA.set("start_time",  timestamp);
                        recA.set("end_time",    timestamp);
                        recA.set("is_active",   true);
                        recA.set("status",      newActiveStatus);
                        recA.set("total_steps", steps);
                        e.app.save(recA);
                        activeActivity = recA;
                        console.log(`[NUOVA] board=${boardId} nuova sessione | status="${newActiveStatus}"`);
                    }

                } else {
                    // Nessuna activity in DB: prima sessione in assoluto
                    const colA = e.app.findCollectionByNameOrId("activities");
                    const recA = new Record(colA);
                    recA.set("board_id",    boardId);
                    recA.set("start_time",  timestamp);
                    recA.set("end_time",    timestamp);
                    recA.set("is_active",   true);
                    recA.set("status",      newActiveStatus);
                    recA.set("total_steps", steps);
                    e.app.save(recA);
                    activeActivity = recA;
                    console.log(`[PRIMA SESSIONE] board=${boardId} | status="${newActiveStatus}"`);
                }
            }

        } catch (err) { console.log("-> activities ERRORE: " + err); }

        // ── 3. POSIZIONI ─────────────────────────────────────────────────────
        // Salviamo la posizione se le coordinate sono valide.
        // activeActivity è valorizzata in tutti i casi (sleep incluso).
        if (hasCoords) {
            try {
                const colP = e.app.findCollectionByNameOrId("positions");
                const recP = new Record(colP);
                recP.set("board_id",  boardId);
                recP.set("timestamp", timestamp);
                recP.set("lat",       lat);
                recP.set("lon",       lon);

                if (activeActivity) {
                    recP.set("activity", activeActivity.getString("id"));
                }

                e.app.save(recP);
                console.log(`[POSITION] board=${boardId} salvata | activity=${activeActivity ? activeActivity.getString("id") : "NULL"}`);
            } catch (err) { console.log("-> positions ERRORE: " + err); }
        }

    } catch (globalErr) {
        console.log("--- ERRORE CRITICO MAIN ---: " + globalErr);
    } finally {
        e.next();
    }
}, "data_sent_raw");

// ═══════════════════════════════════════════════════════════════
//  HOOK: Notifiche al cambio status su activities (onCreate)
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    const utils  = require(`${__hooks}/utils.js`);
    const record  = e.record;
    const boardId = record.getString("board_id");
    const status  = record.getString("status");

    // Mappa status → evento
    const eventMap = {
        "i": ["status_inside",      "Animale nella zona sicura"],
        "v": ["status_trip",        "Animale in viaggio su veicolo"],
        "s": ["status_search",      "Animale fuori zona — ricerca attiva"],
        "w": ["status_walk",        "Animale in passeggiata"],
        // stati sleep
        "d": ["status_sleep_i",     "Animale a riposo in zona sicura"],
        "a": ["status_trip_sleep",  "Animale in sleep durante il viaggio"],
        "p": ["status_sleep_s",     "Animale a riposo fuori zona (allarme)"],
        "z": ["status_sleep_w",     "Animale a riposo fuori zona (passeggiata)"],
    };

    try {
        const entry = eventMap[status];
        if (entry) {
            utils.salvaEvento(e.app, boardId, entry[0], entry[1]);
        }
    } catch (err) {
        console.log("[ACTIVITY CREATE HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");

// ═══════════════════════════════════════════════════════════════
//  HOOK: Notifiche al cambio status su activities (onUpdate)
//  Gestisce le transizioni sleep ↔ attivo sulla stessa sessione
// ═══════════════════════════════════════════════════════════════

onRecordAfterUpdateSuccess((e) => {
    const utils  = require(`${__hooks}/utils.js`);
    const record  = e.record;
    const boardId = record.getString("board_id");
    const status  = record.getString("status");
    const isActive = record.getBool("is_active");

    // Notifichiamo solo le transizioni su sessioni ancora aperte
    if (!isActive) {
        e.next();
        return;
    }

    const eventMap = {
        "v": ["status_trip",       "Animale in viaggio su veicolo"],
        "a": ["status_trip_sleep", "Animale in sleep durante il viaggio"],
        "i": ["status_inside",     "Animale rientrato in zona sicura"],
        "s": ["status_search",     "Animale fuori zona — ricerca attiva"],
        "w": ["status_walk",       "Animale in passeggiata"],
    };

    try {
        const entry = eventMap[status];
        if (entry) {
            utils.salvaEvento(e.app, boardId, entry[0], entry[1]);
        }
    } catch (err) {
        console.log("[ACTIVITY UPDATE HOOK ERRORE] " + err);
    } finally {
        e.next();
    }
}, "activities");


// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog inattività — chiude sessioni appese
//
//  Timeout differenziati per status (is_active = true):
//    "i", "s", "w", "v"  →  10 minuti  (stati attivi normali)
//    "a"                  →  60 minuti  (trip-sleep: viaggio senza segnale)
//
//  I sleep normali (d, p, z) hanno is_active = false → non toccati.
// ═══════════════════════════════════════════════════════════════
// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog inattività — chiude sessioni appese
// ═══════════════════════════════════════════════════════════════

cronAdd("watchdog_device_silence", "* * * * *", () => {
    const WATCHDOG_TIMEOUT_ACTIVE_MS     = 10 * 60 * 1000;
    const WATCHDOG_TIMEOUT_TRIP_SLEEP_MS = 60 * 60 * 1000;
    
    const utils = require(`${__hooks}/utils.js`);
    const now   = new Date();

    try {
        const activeActivities = $app.findRecordsByFilter("activities", "is_active = true", "", 0, 0);
        if (!activeActivities) return;

        activeActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const status     = activity.getString("status");
            const endTimeStr = activity.getString("end_time");
            if (!endTimeStr) return;

            const timeoutMs = status === "a"
                ? WATCHDOG_TIMEOUT_TRIP_SLEEP_MS
                : WATCHDOG_TIMEOUT_ACTIVE_MS;

            const endTimeNormalized = endTimeStr.replace(" ", "T");
            const elapsed = now - new Date(endTimeNormalized);

            if (isNaN(elapsed)) {
                console.log(`[WATCHDOG] Timestamp non parsabile board=${boardId}: "${endTimeStr}" — skip`);
                return;
            }

            if (elapsed >= timeoutMs) {
                activity.set("is_active", false);
                activity.set("end_time",  now.toISOString());
                activity.set("anomaly",   true);
                $app.save(activity);
                utils.salvaEvento($app, boardId, "watchdog", `Chiusura automatica per inattività (status: ${status}, ${(elapsed / 60000).toFixed(1)}m)`);
                console.log(`[WATCHDOG] board=${boardId} status="${status}" chiusa (${(elapsed / 60000).toFixed(1)}m, timeout=${timeoutMs / 60000}m)`);
            }
        });
    } catch (err) {
        console.log("[WATCHDOG ERRORE] " + err);
    }
});