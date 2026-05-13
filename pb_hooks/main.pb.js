// ═══════════════════════════════════════════════════════════════
// File: main.pb.js  ← unico file *.pb.js, caricato da PocketBase
// ═══════════════════════════════════════════════════════════════
//
// Struttura moduli:
//   constants.js        — costanti condivise (stati, timeout, URL)
//   utils.js            — helpers board, batteria, notifiche, geofence, computeStatus
//   activity_manager.js — macchina a stati activity (STEP 1-2-3-4)
//
// Tutti i require sono DENTRO gli handler perché ogni handler
// viene eseguito in un contesto isolato (vedere docs PocketBase JS).
// Il require è cachato dopo il primo caricamento, quindi non
// comporta overhead reale nelle chiamate successive.
//
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
// HOOK: Smistamento pacchetti — data_sent_raw
//
// Riceve ogni pacchetto GPS/sensori dal dispositivo e:
//  1. Salva i dati batteria in battery_data
//  2. Aggiorna la macchina a stati in activities
//  3. Salva la posizione GPS in positions (se coords valide)
// ═══════════════════════════════════════════════════════════════

onRecordAfterCreateSuccess((e) => {
    console.log("[DEBUG] Hook data_sent_raw attivato per record " + e.record.id);

    // Carica i moduli all'interno dell'handler: ogni handler gira in un
    // contesto isolato, ma il require è cachato dopo il primo caricamento
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

    // Estrazione campi dal record raw
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
        // Recupera il record board una sola volta e passa il risultato
        // a tutte le funzioni successive per evitare query ridondanti
        const board = utils.getBoardRecord(e.app, imei);
        if (!board) {
            console.log(`[DEBUG] ERRORE: Board non trovata per IMEI ${imei}`);
            return;
        }

        console.log(`[DEBUG] Inizio processing pacchetto | BoardID: ${board.id} | Status: Sleep=${sleep}, Trip=${trip}, Steps=${steps}`);

        // ── 1. BATTERIA ──────────────────────────────────────────────────────
        // Salva battery_data e notifica se lo stato batteria è cambiato
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
        // Restituisce il record activity aggiornato/creato,
        // oppure null se il pacchetto è stato scartato (sleep duplicato)
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

        // Pacchetto sleep scartato: nessuna posizione da salvare
        if (activeActivity === null) return;

        // ── 3. POSIZIONI ─────────────────────────────────────────────────────
        // Salva la posizione GPS solo se le coordinate sono valide
        // e c'è un'activity attiva a cui collegarla
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
        // finally garantisce che e.next() venga sempre chiamato,
        // anche in caso di return anticipato nel try
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
//
// Eseguito ogni minuto.
// Se un'activity attiva non riceve pacchetti per WATCHDOG_TIMEOUT_MS
// (10 minuti) viene chiusa con anomaly=true e viene inviata una
// notifica push agli utenti della board.
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
        // (il vecchio limite a 100 poteva lasciare board non controllate)
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
                console.log(`[WATCHDOG] -> Scaduto! Chiusura board ${boardId}`);
                activity.set("is_active", false);
                activity.set("anomaly",   true);
                $app.save(activity);

                // Notifica utenti: recupera la board per avere gli userId.
                // Se la board è stata eliminata dal DB, getBoardRecord restituisce null
                // e notifyBoardUsers gestisce silenziosamente il caso (nessun utente).
                const board = utils.getBoardRecord($app, boardId);
                if (!board) console.log(`[WATCHDOG] Board ${boardId} non trovata nel DB, notifica saltata`);
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
// Schedulato su "59 21,22 * * *" per coprire sia ora legale che solare:
//  - Estate CEST (UTC+2): 21:59 UTC = 23:59 italiana -> esegue
//                         22:59 UTC = 00:59 italiana -> skip
//  - Inverno CET  (UTC+1): 22:59 UTC = 23:59 italiana -> esegue
//                          21:59 UTC = 22:59 italiana -> skip
//
// Il check interno italyHour===23 && italyMinute===59 filtra il tick
// non pertinente senza bisogno di due cron separati.
//
// Timestamp fine/inizio giorno:
//  - Calcolati sottraendo l'offset dinamico dalla mezzanotte italiana
//  - Estate: fine=21:59:59 UTC, inizio=22:00:00 UTC
//  - Inverno: fine=22:59:59 UTC, inizio=23:00:00 UTC
//
// Per ogni board (prende solo la activity con end_time più recente):
//  - Activity attiva      -> chiude a fineGiornoISO, apre nuova a inizioGiornoISO
//  - Activity in sleep    -> chiude il sleep a fineGiornoISO, apre nuovo sleep
//  - Activity con anomaly -> ignorata (già gestita dal watchdog)
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

    // Calcola l'ora italiana corrente e l'offset dinamico UTC↔Italia
    const italyNowMs = utils.getItalyTime();
    const nowUTC     = new Date();
    const offsetMs   = italyNowMs - nowUTC.getTime(); // 7200000 (CEST) o 3600000 (CET)

    const italyNow    = new Date(italyNowMs);
    const italyHour   = italyNow.getUTCHours();
    const italyMinute = italyNow.getUTCMinutes();

    // Filtra il tick non pertinente (es. 22:59 UTC in estate = 00:59 italiana)
    if (italyHour !== 23 || italyMinute !== 59) {
        console.log(`[MEZZANOTTE] ora Italia: ${italyHour}:${italyMinute < 10 ? "0" : ""}${italyMinute} — skip`);
        return;
    }

    console.log(`[MEZZANOTTE] ora Italia: 23:59 — avvio split giornaliero`);

    // Costruisce la mezzanotte italiana come oggetto UTC "grezzo"
    // poi sottrae l'offset per ottenere il timestamp UTC reale
    const midnightItaly = new Date(Date.UTC(
        italyNow.getUTCFullYear(),
        italyNow.getUTCMonth(),
        italyNow.getUTCDate() + 1, // domani in ora italiana
        0, 0, 0
    ));
    const midnightUTC = new Date(midnightItaly.getTime() - offsetMs);

    const fineGiornoISO   = new Date(midnightUTC.getTime() - 1000).toISOString(); // 21:59:59 UTC (estate) / 22:59:59 UTC (inverno)
    const inizioGiornoISO = midnightUTC.toISOString();                            // 22:00:00 UTC (estate) / 23:00:00 UTC (inverno)

    console.log(`[MEZZANOTTE] fine=${fineGiornoISO} | inizio=${inizioGiornoISO}`);

    try {
        // Recupera tutte le activity attive O in stato sleep senza anomalia.
        // Include tutti gli stati sleep: a, q, d, p, z
        const targetActivities = $app.findRecordsByFilter(
            "activities",
            "is_active = true || (is_active = false && anomaly != true && (status = 'd' || status = 'a' || status = 'q' || status = 'p' || status = 'z'))",
            "",
            0,
            0
        );
        if (!targetActivities || targetActivities.length === 0) return;

        // Per ogni board tiene solo la activity con end_time più recente.
        // Evita di processare sessioni obsolete della stessa board.
        const latestByBoard = {};
        targetActivities.forEach(activity => {
            const boardId    = activity.getString("board_id");
            const lastSeenMs = Date.parse(activity.getString("end_time").replace(" ", "T"));

            if (!latestByBoard[boardId] || lastSeenMs > latestByBoard[boardId].lastSeenMs) {
                latestByBoard[boardId] = { activity, lastSeenMs };
            }
        });

        // Carica la collection una volta sola fuori dal loop
        // per evitare query ridondanti ad ogni iterazione
        const col = $app.findCollectionByNameOrId("activities");

        Object.entries(latestByBoard).forEach(([boardId, { activity, lastSeenMs }]) => {
            try {
                const isActive = activity.getBool("is_active");
                const status   = activity.getString("status");

                // Activity attiva scaduta: il watchdog se ne è già occupato -> skip
                // Non tocchiamo i record con anomaly, li lasciamo al watchdog
                if (isActive) {
                    const elapsed = italyNowMs - lastSeenMs;
                    if (!isNaN(elapsed) && elapsed >= WATCHDOG_TIMEOUT_MS) {
                        console.log(`[MEZZANOTTE] Board ${boardId} scaduta (watchdog) -> skip`);
                        return;
                    }
                }

                if (isActive) {
                    // Activity attiva: chiude la sessione del giorno corrente e apre una nuova sessione identica per il giorno nuovo.
                    // I due save sono separati: se il secondo fallisce la sessione
                    // vecchia è già chiusa, ma il primo pacchetto del nuovo giorno
                    // creerà automaticamente una nuova sessione al risveglio.
                    activity.set("is_active", false);
                    activity.set("end_time",  fineGiornoISO);
                    $app.save(activity);

                    try {
                        const newRec = new Record(col);
                        newRec.set("board_id",   boardId);
                        newRec.set("start_time", inizioGiornoISO);
                        newRec.set("end_time",   inizioGiornoISO);
                        newRec.set("is_active",  true);
                        newRec.set("status",     status);
                        $app.save(newRec);
                        console.log(`[MEZZANOTTE] Board ${boardId} attiva -> split con status "${status}"`);
                    } catch (saveErr) {
                        console.log(`[MEZZANOTTE] ERRORE apertura nuova sessione board ${boardId}: ` + saveErr);
                        // La sessione vecchia è già chiusa. Il primo pacchetto del giorno
                        // nuovo creerà una nuova sessione automaticamente via hook.
                    }

                } else if (utils.SLEEP_STATES.has(status)) {
                    // Activity in sleep: converte lo stato sleep -> attivo per chiuderlo
                    // correttamente, poi apre un nuovo record sleep per il giorno nuovo.
                    const wakeStatus = utils.SLEEP_TO_ACTIVE[status];
                    activity.set("status",   wakeStatus);
                    activity.set("end_time", fineGiornoISO);
                    $app.save(activity);

                    try {
                        const newSleep = new Record(col);
                        newSleep.set("board_id",   boardId);
                        newSleep.set("start_time", inizioGiornoISO);
                        newSleep.set("end_time",   inizioGiornoISO);
                        newSleep.set("is_active",  false);
                        newSleep.set("status",     status);
                        $app.save(newSleep);
                        console.log(`[MEZZANOTTE] Board ${boardId} sleep "${status}" -> split, sveglia come "${wakeStatus}"`);
                    } catch (saveErr) {
                        console.log(`[MEZZANOTTE] ERRORE apertura nuovo sleep board ${boardId}: ` + saveErr);
                        // Il record sleep vecchio è già stato convertito in attivo.
                        // Al risveglio il sistema non troverà un sleep da riattivare
                        // e creerà una nuova sessione con lo stato calcolato.
                    }
                }

            } catch (err) {
                console.log(`[MEZZANOTTE] Errore board ${boardId}: ` + err);
            }
        });

    } catch (err) {
        console.log("[MEZZANOTTE] Errore generale: " + err);
    }
});