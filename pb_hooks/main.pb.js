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
        // activeActivity è valorizzata in tutti i path così la sezione
        // posizioni può sempre legarla correttamente.
        let activeActivity = null;

        try {
            // Recupera l'activity attiva corrente (se esiste)
            const activeList = e.app.findRecordsByFilter(
                "activities", "board_id = {:id} && is_active = true", "-id", 1, 0, { id: boardId }
                //"activities", "board_id = {:id}", "-end_time", 1, 0, { id: boardId }
            );
            let currentActivity = activeList.length > 0 ? activeList[0] : null;
            console.log(`[currentActivity] ` + currentActivity);

            // Status precedente (attivo o sleep)
            const prevStatus = currentActivity ? currentActivity.getString("status") : null;
            console.log(`[STATUS] ` + prevStatus);

            // ── CALCOLA NUOVO STATUS ─────────────────────────────────────────
            // computeStatus gestisce internamente trip, inside e alarm.
            // Viene chiamato sia per sleep che per sveglio: in caso di sleep
            // il risultato attivo viene poi convertito in sleep.
            const newActiveStatus = utils.computeStatus(
                e.app, boardId, lat, lon, trip, steps, prevStatus
            );

            // ── CASO SLEEP ───────────────────────────────────────────────────
            if (sleep) {
                const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z";

                // Caso speciale: trip-sleep (animale sul veicolo che dorme).
                // La sessione rimane is_active=true in modo da continuare a
                // ricevere posizioni GPS; cambiamo solo lo status in "a".
                const isTripSleep = newActiveStatus === "v";

                if (currentActivity) {
                    const curStatus = currentActivity.getString("status");

                    if (isTripSleep) {
                        // Aggiorna status → "a" solo se non lo era già
                        if (curStatus !== "a") {
                            currentActivity.set("status",   "a");
                            currentActivity.set("end_time", timestamp);
                            e.app.save(currentActivity);
                            console.log(`[SLEEP+TRIP] board=${boardId} status → "a"`);
                        } else {
                            // Già in trip-sleep: aggiorna solo end_time
                            currentActivity.set("end_time", timestamp);
                            e.app.save(currentActivity);
                        }
                        activeActivity = currentActivity; // mantieni per posizioni
                    } else {
                        // Sleep normale: chiudi l'activity attiva
                        // NON azzeriamo activeActivity così la posizione viene
                        // comunque salvata con il riferimento alla sessione chiusa.
                        currentActivity.set("is_active", false);
                        currentActivity.set("end_time",  timestamp);
                        currentActivity.set("status",    sleepStatus);
                        e.app.save(currentActivity);
                        activeActivity = currentActivity;
                        console.log(`[SLEEP] board=${boardId} activity chiusa | status="${sleepStatus}"`);
                    }
                } else {
                    // Nessuna activity attiva in sleep: non creiamo nulla,
                    // ma teniamo activeActivity=null (nessuna posizione da salvare).
                    console.log(`[SLEEP] board=${boardId} nessuna activity attiva, skip`);
                }
            // ── CASO SVEGLIO ─────────────────────────────────────────────────
            } else {
                if (currentActivity) {
                    const curStatus = currentActivity.getString("status");
                    const isCurSleep = utils.SLEEP_STATES.has(curStatus);
                    
                    // Normalizza status sleep corrente → attivo per confronto
                    const curActiveStatus = isCurSleep
                        ? (utils.SLEEP_TO_ACTIVE[curStatus] ?? curStatus)
                        : curStatus;

                    if (newActiveStatus === curActiveStatus) {
                        // Stesso stato: aggiorna la sessione esistente
                        currentActivity.set("status",      newActiveStatus); // risveglia da sleep
                        currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
                        currentActivity.set("end_time",    timestamp);
                        currentActivity.set("is_active", true); // in caso fosse dormiente ma si sveglia senza cambiare stato (es. "d" → "i")
                        e.app.save(currentActivity);
                        activeActivity = currentActivity;
                        console.log(`[RIPRESA] stessa azione`);

                    } else {
                        // Cambio di stato: chiudi la sessione corrente e aprine una nuova
                        currentActivity.set("is_active", false);
                        currentActivity.set("end_time",  timestamp);
                        
                        // FIX: Se era dormiente ma si sveglia in un altro stato, 
                        // salviamo la vecchia activity con il suo stato attivo originale
                        if (isCurSleep) {
                            currentActivity.set("status", curActiveStatus);
                        }

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
                        console.log(`[ACTIVITY] board=${boardId} cambio stato "${curStatus}" → "${newActiveStatus}"`);
                    }
                } else {
                    // Nessuna activity attiva: controlla le sessioni chiuse di recente
                    const recentClosed = e.app.findRecordsByFilter(
                        "activities", "board_id = {:id} && is_active = false", "-id", 1, 0, { id: boardId }
                    );

                    if (recentClosed.length > 0) {
                        const closed       = recentClosed[0];
                        const closedAtStr  = closed.getString("end_time");
                        const closedStatus = closed.getString("status");
                        
                        const isClosedSleep = utils.SLEEP_STATES.has(closedStatus);
                        
                        // Normalizza status sleep → attivo
                        const closedActive = isClosedSleep
                            ? (utils.SLEEP_TO_ACTIVE[closedStatus] ?? closedStatus)
                            : closedStatus;

                        const endTimeNorm = closedAtStr.replace(" ", "T");
                        const diffSec     = (new Date(timestamp) - new Date(endTimeNorm)) / 1000;

                        // Valuta se l'attività compatibile riparte
                        const sameOrCompatible = (closedActive === newActiveStatus) || (closedStatus === "a" && newActiveStatus === "v");

                        let shouldReactivate = false;

                        // FIX: Se la sessione era chiusa perché dormiva E si risveglia nello stesso stato
                        // bypassiamo il limite di tempo e riattiviamo (riprende la stessa azione)
                        if (isClosedSleep && sameOrCompatible) {
                            shouldReactivate = true;
                        } 
                        // Se non dormiva, ma è un micro-gap, applichiamo il dedup normale
                        else if (!isNaN(diffSec) && diffSec >= 0 && diffSec < utils.SESSION_DEDUP_SEC && sameOrCompatible) {
                            shouldReactivate = true;
                        }

                        if (shouldReactivate) {
                            closed.set("is_active",   true);
                            closed.set("end_time",    timestamp);
                            closed.set("status",      newActiveStatus);
                            closed.set("total_steps", closed.getInt("total_steps") + steps);
                            e.app.save(closed);
                            activeActivity = closed;
                            console.log(`[RISVEGLIO/DEDUP] board=${boardId} sessione riattivata ("${closedStatus}"→"${newActiveStatus}")`);
                        } else {
                            // FIX: Se cambia stato (es. "p" -> "v" o "w"), non la riattiviamo.
                            // Prima di crearne una nuova, cambiamo il vecchio stato sleep nella sua versione attiva.
                            if (isClosedSleep) {
                                closed.set("status", closedActive);
                                e.app.save(closed);
                                console.log(`[POST-SLEEP UPDATE] board=${boardId} sessione chiusa corretta ("${closedStatus}" → "${closedActive}")`);
                            }
                        }
                    }

                    // Nessuna sessione riattivabile: crea una nuova
                    if (!activeActivity) {
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
                        console.log(`[ACTIVITY] board=${boardId} nuova sessione | status="${newActiveStatus}"`);
                    }
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
// ═══════════════════════════════════════════════════════════════
//  CRON: Mezzanotte — spezza le sessioni sleep per giorno
//
//  Alla mezzanotte ogni sessione sleep aperta (is_active=false,
//  status in d/p/z) viene:
//    1. Chiusa con lo status attivo corrispondente (d→i, p→s, z→w)
//    2. Riaperta immediatamente con lo stesso status sleep
//
//  Questo garantisce che ogni giorno abbia le proprie sessioni
//  e che le statistiche giornaliere siano corrette.
//  "a" (trip-sleep) è is_active=true → gestito dal watchdog, non qui.
// ═══════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════
//  CRON: Mezzanotte — spezza le sessioni sleep per giorno
//
//  Gestisce tutti gli stati sleep alla mezzanotte:
//    d/p/z (is_active=false) → chiude con stato attivo, riapre con sleep
//    a     (is_active=true)  → chiude con "v" + is_active=false,
//                              riapre con "a" + is_active=true
// ═══════════════════════════════════════════════════════════════

cronAdd("midnight_sleep_split", "0 0 * * *", () => {
    const utils = require(`${__hooks}/utils.js`);

    const SLEEP_TO_ACTIVE_MAP = { d: "i", p: "s", z: "w", a: "v" };

    const midnight = new Date();
    midnight.setSeconds(0);
    midnight.setMilliseconds(0);
    const midnightISO = midnight.toISOString();

    console.log(`[MIDNIGHT] Avvio split sessioni sleep — ${midnightISO}`);

    try {
        // d/p/z → is_active=false | a → is_active=true
        const sleepActivities = $app.findRecordsByFilter(
            "activities",
            "(is_active = false && (status = 'd' || status = 'p' || status = 'z')) || (is_active = true && status = 'a')",
            "", 0, 0
        );

        if (!sleepActivities || sleepActivities.length === 0) {
            console.log("[MIDNIGHT] Nessuna sessione sleep da spezzare");
            return;
        }

        // Teniamo solo l'ultima sessione per board_id
        const latestByBoard = {};
        sleepActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const endTimeStr = activity.getString("end_time").replace(" ", "T");
            const endTime    = new Date(endTimeStr);

            if (!latestByBoard[boardId] || endTime > latestByBoard[boardId].endTime) {
                latestByBoard[boardId] = { activity, endTime };
            }
        });

        Object.entries(latestByBoard).forEach(([boardId, { activity }]) => {
            try {
                const sleepStatus  = activity.getString("status");
                const activeStatus = SLEEP_TO_ACTIVE_MAP[sleepStatus];

                if (!activeStatus) {
                    console.log(`[MIDNIGHT] board=${boardId} status="${sleepStatus}" non mappato, skip`);
                    return;
                }

                const isTripSleep = sleepStatus === "a";

                // 1. Chiudi sessione corrente con stato ATTIVO e is_active=false
                activity.set("status",    activeStatus);
                activity.set("end_time",  midnightISO);
                activity.set("is_active", false);
                $app.save(activity);
                console.log(`[MIDNIGHT] board=${boardId} "${sleepStatus}"→"${activeStatus}" chiusa`);

                // 2. Nuova sessione con stesso stato SLEEP
                //    "a" rimane is_active=true perché il viaggio è ancora in corso
                const col  = $app.findCollectionByNameOrId("activities");
                const newA = new Record(col);
                newA.set("board_id",    boardId);
                newA.set("start_time",  midnightISO);
                newA.set("end_time",    midnightISO);
                newA.set("is_active",   isTripSleep);
                newA.set("status",      sleepStatus);
                newA.set("total_steps", 0);
                $app.save(newA);
                console.log(`[MIDNIGHT] board=${boardId} nuova "${sleepStatus}" is_active=${isTripSleep}`);

            } catch (err) {
                console.log(`[MIDNIGHT] board=${boardId} ERRORE: ` + err);
            }
        });

    } catch (err) {
        console.log("[MIDNIGHT ERRORE] " + err);
    }
});