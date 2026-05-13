// ═══════════════════════════════════════════════════════════════
// File: activity_manager.js
// Macchina a stati activity: STEP 1-2-3-4
// ═══════════════════════════════════════════════════════════════
//
// FLUSSO processActivity:
//
//  STEP 1 — Cerca l'activity attiva (is_active=true) per la board
//
//  STEP 3 anticipato — Se non c'è activity attiva E sleep=true:
//             -> scarta il pacchetto (return null)
//             -> evita notifiche spurie da sleep duplicati consecutivi
//
//  STEP 2a — Se non c'è activity attiva, cerca l'ultimo sleep (per prevStatus)
//  STEP 2b — Calcola il nuovo stato attivo via computeStatus
//             -> prevStatus passato correttamente per evitare notifiche spurie
//             -> fatto PRIMA del risveglio per confrontare col wakeStatus
//
//  STEP 3 — Se non c'è activity attiva E sleep=false (risveglio):
//             -> cerca l'ultimo record sleep chiuso (anomaly=false)
//             -> converte SEMPRE lo stato sleep -> attivo (chiude correttamente il periodo)
//             -> se wakeStatus == newActiveStatus: riapre la sessione esistente
//             -> altrimenti: lascia chiusa, sotto verrà creata una nuova sessione
//
//  STEP 4 — Aggiorna l'activity in base allo stato:
//             sleep=true            -> chiude con ACTIVE_TO_SLEEP[newActiveStatus]
//             stesso stato          -> estende end_time e accumula steps
//             stato diverso         -> chiude e crea nuova sessione
//             nessuna + sleep=false -> crea nuova sessione
//
// RETURNS:
//  {object} - record activity aggiornato/creato (da usare per salvare la posizione)
//  null     - pacchetto scartato (sleep duplicato), nessuna scrittura su activity
//
// ═══════════════════════════════════════════════════════════════

/**
 * Processa la macchina a stati activity per un singolo pacchetto in arrivo.
 *
 * @param {object}  app
 * @param {object}  utils     - modulo utils già caricato (evita require multipli)
 * @param {object}  board     - record board già letto (evita query ridondanti)
 * @param {string}  timestamp - ISO timestamp del pacchetto
 * @param {boolean} sleep     - dispositivo in sleep
 * @param {boolean} trip      - dispositivo su veicolo (confermato al 2° pacchetto)
 * @param {number}  steps     - passi nel periodo
 * @param {number}  lat       - latitudine (0.0 = non disponibile)
 * @param {number}  lon       - longitudine (0.0 = non disponibile)
 * @returns {object|null}     - record activity attivo, o null se pacchetto scartato
 */
function processActivity(app, utils, board, timestamp, sleep, trip, steps, lat, lon) {

    // ── STEP 1: Cerca activity attiva ────────────────────────────────────────
    // Cerca l'unica activity con is_active=true per questa board.
    // In condizioni normali ne esiste al massimo una alla volta.
    const activeList = app.findRecordsByFilter(
        "activities",
        "board_id = {:id} && is_active = true",
        "-end_time",
        1,
        0,
        { id: board.id }
    );

    let currentActivity = activeList.length > 0 ? activeList[0] : null;
    console.log(`[DEBUG] Activity attiva trovata: ${currentActivity ? currentActivity.id : "nessuna"}`);

    // ── STEP 3 anticipato: scarta sleep senza activity attiva ────────────────
    // Se arriva sleep=true ma non c'è nessuna activity attiva significa che
    // il dispositivo era già dormiente -> pacchetto duplicato -> scarta.
    // Questo blocco è anticipato rispetto a computeStatus per evitare
    // che vengano inviate notifiche spurie (computeStatus le emette internamente).
    if (!currentActivity && sleep) {
        console.log(`[DEBUG] Pacchetto sleep senza activity attiva -> scartato`);
        return null;
    }

    // ── STEP 2a: Cerca ultimo sleep se non c'è activity attiva ─────────────
    // Fatto PRIMA di computeStatus per passare il prevStatus corretto.
    // Senza questo, computeStatus riceverebbe null come prevStatus e
    // invierebbe notifiche spurie al risveglio (ogni stato != null).
    let recentClosed = null;
    if (!currentActivity) {
        const recentList = app.findRecordsByFilter(
            "activities",
            "board_id = {:id} && is_active = false && anomaly != true && (status = 'a' || status = 'q' || status = 'z' || status = 'p' || status = 'd')",
            "-end_time",
            1,
            0,
            { id: board.id }
        );
        recentClosed = recentList.length > 0 ? recentList[0] : null;
        console.log(`[DEBUG] Ultimo sleep trovato: ${recentClosed ? recentClosed.id + " status=" + recentClosed.getString("status") : "nessuno"}`);
    }

    // ── STEP 2b: Calcolo nuovo stato ─────────────────────────────────────────
    // prevStatus viene ricavato da:
    //  - currentActivity.status  se c'è una sessione attiva
    //  - recentClosed.status     se c'è un sleep precedente (risveglio)
    //  - null                    solo al primo avvio assoluto o dopo watchdog
    // Passare il prevStatus corretto evita notifiche spurie al risveglio:
    // computeStatus normalizza "a"->"v", "q"->"r" ecc. e confronta
    // effectivePrev col nuovo stato prima di inviare qualsiasi notifica.
    const prevStatusForCompute = currentActivity
        ? currentActivity.getString("status")
        : (recentClosed ? recentClosed.getString("status") : null);

    const newActiveStatus = utils.computeStatus(
        app,
        board,
        board.id,
        lat,
        lon,
        trip,
        steps,
        prevStatusForCompute
    );
    console.log(`[DEBUG] Nuovo stato calcolato: ${newActiveStatus} (prevStatus: ${prevStatusForCompute ?? "null"})`);

    // ── STEP 3: Logica di risveglio ──────────────────────────────────────────
    // Raggiunto solo se: currentActivity=null AND sleep=false
    // (il caso sleep=true è già stato scartato sopra)
    if (!currentActivity) {

        console.log(`[DEBUG] Risveglio query: trovato=${recentClosed ? recentClosed.id : "null"} | status="${recentClosed ? recentClosed.getString("status") : "-"}" | anomaly=${recentClosed ? recentClosed.getBool("anomaly") : "-"} | isSleep=${recentClosed ? utils.SLEEP_STATES.has(recentClosed.getString("status")) : "-"}`);

        if (recentClosed && utils.SLEEP_STATES.has(recentClosed.getString("status"))) {
            const sleepStatus = recentClosed.getString("status");    // es. "q"
            const wakeStatus  = utils.SLEEP_TO_ACTIVE[sleepStatus];  // es. "q" -> "r"

            // Converte SEMPRE lo stato sleep -> attivo corrispondente.
            // Questo chiude correttamente il periodo sleep nel DB
            // indipendentemente da cio che faremo con is_active.
            recentClosed.set("status", wakeStatus);
            app.save(recentClosed);
            console.log(`[DEBUG] Sleep chiuso correttamente: ${sleepStatus} -> ${wakeStatus}`);

            if (wakeStatus === newActiveStatus) {
                // Risveglio conforme: lo stato atteso corrisponde allo stato calcolato
                // -> riapriamo la sessione esistente invece di crearne una nuova
                recentClosed.set("is_active", true);
                app.save(recentClosed);
                currentActivity = recentClosed;
                console.log(`[DEBUG] Risveglio conforme: sessione ${recentClosed.id} riaperta in stato "${wakeStatus}"`);
            } else {
                // Risveglio non conforme: lo stato calcolato e diverso da quello atteso
                // -> la sessione sleep resta chiusa col suo stato attivo corretto,
                //   sotto verra creata una nuova sessione con newActiveStatus
                console.log(`[DEBUG] Risveglio non conforme: sleep="${sleepStatus}" wake="${wakeStatus}" nuovo="${newActiveStatus}" -> nuova sessione`);
            }
            // Nota: se recentClosed.set("status") o app.save falliscono qui,
            // l'eccezione si propaga al catch dell'hook che logga il problema.
            // Il record sleep rimane con lo stato originale, nessuna sessione
            // viene riaperta, e il flusso si interrompe in modo sicuro.
        }
        // Se nessun sleep trovato o anomaly=true -> currentActivity resta null
        // -> STEP 4 creera una nuova sessione
    }

        // ── STEP 4: Aggiornamento activity ───────────────────────────────────────
    let activeActivity = null;

    if (currentActivity) {
        const rawPrevStatus  = currentActivity.getString("status");
        // Normalizza il prevStatus per il confronto (gestisce il caso in cui
        // la sessione fosse stata riaperta con uno stato sleep temporaneo)
        const normalizedPrev = utils.SLEEP_TO_ACTIVE[rawPrevStatus] ?? rawPrevStatus;

        if (sleep) {
            // Dispositivo in sleep: chiude la sessione con lo stato sleep
            // corrispondente al nuovo stato calcolato.
            // Es: newActiveStatus="r" -> sleepStatus="q"
            const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z";
            currentActivity.set("is_active", false);
            currentActivity.set("end_time",  timestamp);
            currentActivity.set("status",    sleepStatus);
            app.save(currentActivity);
            activeActivity = currentActivity;
            console.log(`[DEBUG] Dispositivo in sleep: sessione chiusa con stato "${sleepStatus}"`);

        } else if (newActiveStatus === normalizedPrev) {
            // Stesso stato: estende la sessione corrente aggiornando end_time
            // e accumulando i passi del periodo
            currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
            currentActivity.set("end_time", timestamp);
            app.save(currentActivity);
            activeActivity = currentActivity;

        } else {
            // Cambio stato: chiude la sessione corrente e ne apre una nuova
            // con il nuovo stato calcolato
            console.log(`[DEBUG] Transizione stato: ${normalizedPrev} -> ${newActiveStatus}`);
            currentActivity.set("is_active", false);
            currentActivity.set("end_time",  timestamp);
            app.save(currentActivity);

            activeActivity = utils.createNewActivity(app, board.id, timestamp, newActiveStatus, steps);
            if (!activeActivity) {
                console.log(`[DEBUG] ERRORE: createNewActivity fallita dopo transizione ${normalizedPrev} -> ${newActiveStatus}`);
            }
        }

    } else if (!sleep) {
        // Nessuna activity attiva e dispositivo sveglio:
        // prima sessione assoluta o dopo una anomalia watchdog
        activeActivity = utils.createNewActivity(app, board.id, timestamp, newActiveStatus, steps);
        if (!activeActivity) {
            console.log(`[DEBUG] ERRORE: createNewActivity fallita per nuova sessione status=${newActiveStatus}`);
        }
    }
    // Caso sleep=true e currentActivity=null: già scartato in STEP 3 anticipato

    return activeActivity;
}

module.exports = { processActivity };