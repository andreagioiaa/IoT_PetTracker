// ═══════════════════════════════════════════════════════════════
// File: activity_manager.js
// Macchina a stati activity: STEP 1-2-3-4
// ═══════════════════════════════════════════════════════════════
//
// FLUSSO:
//
//  STEP 1 — Cerca activity attiva per la board
//  STEP 2 — Calcola nuovo stato (computeStatus)
//  STEP 3 — Se nessuna activity attiva:
//             sleep=true  → scarta pacchetto (return null)
//             sleep=false → cerca ultimo sleep chiuso e tenta risveglio
//  STEP 4 — Aggiorna activity:
//             sleep=true          → chiude con stato sleep
//             stesso stato        → estende end_time e steps
//             stato diverso       → chiude e crea nuova
//             nessuna + sveglio   → crea nuova
//
// RETURNS: record activity aggiornato/creato,
//          null se il pacchetto è stato scartato (sleep duplicato)
//
// ═══════════════════════════════════════════════════════════════

/**
 * Processa la macchina a stati activity per un pacchetto in arrivo.
 *
 * @param {object}  app
 * @param {object}  utils       - modulo utils già caricato
 * @param {object}  board       - record board già letto
 * @param {string}  timestamp
 * @param {boolean} sleep
 * @param {boolean} trip
 * @param {number}  steps
 * @param {number}  lat
 * @param {number}  lon
 * @returns {object|null}       - record activity attivo, o null se scartato
 */
function processActivity(app, utils, board, timestamp, sleep, trip, steps, lat, lon) {

    // ── STEP 1: Cerca activity attiva ────────────────────────────────────────
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
    // Evita che computeStatus (e le sue notifiche) vengano invocati inutilmente
    // quando arriva un secondo pacchetto sleep consecutivo.
    if (!currentActivity && sleep) {
        console.log(`[DEBUG] Pacchetto sleep senza activity attiva → scartato`);
        return null;
    }

    // ── STEP 2: Calcolo nuovo stato ──────────────────────────────────────────
    // Va fatto PRIMA del risveglio per confrontare col wakeStatus
    const newActiveStatus = utils.computeStatus(
        app,
        board,
        board.id,
        lat,
        lon,
        trip,
        steps,
        currentActivity ? currentActivity.getString("status") : null
    );
    console.log(`[DEBUG] Nuovo stato calcolato: ${newActiveStatus}`);

    // ── STEP 3: Logica di risveglio ──────────────────────────────────────────
    // Raggiunto solo se currentActivity=null e sleep=false
    if (!currentActivity) {
        const recentList = app.findRecordsByFilter(
            "activities",
            "board_id = {:id} && is_active = false && anomaly != true && (status = 'a' || status = 'z' || status = 'p' || status = 'd')",
            "-end_time",
            1,
            0,
            { id: board.id }
        );
        const recentClosed = recentList.length > 0 ? recentList[0] : null;

        console.log(`[DEBUG] Risveglio query: trovato=${recentClosed ? recentClosed.id : "null"} | status="${recentClosed ? recentClosed.getString("status") : "-"}" | anomaly=${recentClosed ? recentClosed.getBool("anomaly") : "-"} | isSleep=${recentClosed ? utils.SLEEP_STATES.has(recentClosed.getString("status")) : "-"}`);

        if (recentClosed && utils.SLEEP_STATES.has(recentClosed.getString("status"))) {
            const sleepStatus = recentClosed.getString("status");   // es. "p"
            const wakeStatus  = utils.SLEEP_TO_ACTIVE[sleepStatus]; // es. "p" → "s"

            // Converte SEMPRE il record sleep nel suo attivo corrispondente.
            // Chiude correttamente il periodo sleep indipendentemente dal nuovo stato.
            recentClosed.set("status", wakeStatus);
            app.save(recentClosed);
            console.log(`[DEBUG] Sleep chiuso correttamente: ${sleepStatus} → ${wakeStatus}`);

            if (wakeStatus === newActiveStatus) {
                // Stato conforme: riapre la sessione esistente
                recentClosed.set("is_active", true);
                app.save(recentClosed);
                currentActivity = recentClosed;
                console.log(`[DEBUG] Risveglio conforme: sessione ${recentClosed.id} riaperta in stato "${wakeStatus}"`);
            } else {
                // Stato non conforme: sessione sleep resta chiusa col suo attivo,
                // sotto verrà creata una nuova sessione col nuovo stato.
                console.log(`[DEBUG] Risveglio non conforme: sleep="${sleepStatus}" wake="${wakeStatus}" nuovo="${newActiveStatus}" → nuova sessione`);
            }
        }
        // Se nessun sleep trovato o anomaly=true → currentActivity resta null → nuova sessione sotto
    }

    // ── STEP 4: Aggiornamento activity ───────────────────────────────────────
    let activeActivity = null;

    if (currentActivity) {
        const rawPrevStatus  = currentActivity.getString("status");
        const normalizedPrev = utils.SLEEP_TO_ACTIVE[rawPrevStatus] ?? rawPrevStatus;

        if (sleep) {
            // Dispositivo in sleep: chiude con lo stato sleep corrispondente
            const sleepStatus = utils.ACTIVE_TO_SLEEP[newActiveStatus] ?? "z";
            currentActivity.set("is_active", false);
            currentActivity.set("end_time",  timestamp);
            currentActivity.set("status",    sleepStatus);
            app.save(currentActivity);
            activeActivity = currentActivity;
            console.log(`[DEBUG] Dispositivo in sleep: sessione chiusa con stato "${sleepStatus}"`);

        } else if (newActiveStatus === normalizedPrev) {
            // Stesso stato: estende la sessione corrente
            currentActivity.set("total_steps", currentActivity.getInt("total_steps") + steps);
            currentActivity.set("end_time", timestamp);
            app.save(currentActivity);
            activeActivity = currentActivity;

        } else {
            // Cambio stato: chiude la sessione corrente e ne apre una nuova
            console.log(`[DEBUG] Transizione stato: ${normalizedPrev} → ${newActiveStatus}`);
            currentActivity.set("is_active", false);
            currentActivity.set("end_time",  timestamp);
            app.save(currentActivity);

            activeActivity = utils.createNewActivity(app, board.id, timestamp, newActiveStatus, steps);
        }

    } else if (!sleep) {
        // Nessuna activity attiva e dispositivo sveglio → crea nuova sessione
        activeActivity = utils.createNewActivity(app, board.id, timestamp, newActiveStatus, steps);
    }
    // sleep=true e currentActivity=null → già scartato in STEP 3 anticipato

    return activeActivity;
}

module.exports = { processActivity };
