// ═══════════════════════════════════════════════════════════════
//  CONFIGURAZIONE
// ═══════════════════════════════════════════════════════════════
const WATCHDOG_TIMEOUT_MIN  = 10; // Minuti di silenzio prima che il watchdog intervenga
const GPS_FAIL_ALERT_THRESH = 3;  // Pacchetti consecutivi senza GPS prima di loggare
const SESSION_DEDUP_SEC     = 30; // Secondi: se esiste già una sessione attiva aperta
                                  // da meno di questo valore, non ne crea una nuova

// ───────────────────────────────────────────────────────────────
//  UTILITY: salva un evento di anomalia in "device_events"
//  Campi richiesti: board_id (text), type (text), detail (text), timestamp (text)
// ───────────────────────────────────────────────────────────────
function salvaEvento(app, boardId, type, detail) {
    try {
        const col = app.findCollectionByNameOrId("device_events");
        const rec = new Record(col);
        rec.set("board_id", boardId);
        rec.set("type",     type);
        rec.set("detail",   detail);
        rec.set("timestamp", new Date().toISOString());
        app.save(rec);
        console.log("[EVENTI] '" + type + "' per board " + boardId + ": " + detail);
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
    const lat          = raw.getFloat("lat");
    const lon          = raw.getFloat("lon");

    console.log(
        "--- SMISTAMENTO | board: " + boardId +
        " | sleep: " + sleep +
        " | steps: " + steps +
        " | gps_valid: " + gpsValid +
        " | gps_fail: " + gpsFailCount +
        " | net_fail: " + netFailCount + " ---"
    );

    // Wrappa tutto in finally per garantire che e.next() venga sempre chiamato
    // anche in caso di errori imprevisti non catturati dai singoli try/catch.
    try {

        // ── 1. BATTERIA ─────────────────────────────────────────────────────
        try {
            const col = e.app.findCollectionByNameOrId("battery_data");
            const rec = new Record(col);
            rec.set("board_id",        boardId);
            rec.set("timestamp",       timestamp);
            rec.set("battery",         raw.getFloat("battery"));
            rec.set("battery_percent", raw.getInt("battery_percent"));
            rec.set("charging",        raw.getBool("charging"));
            e.app.save(rec);
            console.log("-> battery_data: OK");
        } catch (err) {
            console.log("-> battery_data: ERRORE: " + err);
        }

        // ── 2. POSIZIONI ─────────────────────────────────────────────────────
        // Salta se non abbiamo mai avuto coordinate valide (lat=0, lon=0, gps_valid=false)
        const hasCoords = !(lat === 0.0 && lon === 0.0 && !gpsValid);

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
                console.log("-> positions_duplicate: OK (gps_valid=" + gpsValid + ")");
            } catch (err) {
                console.log("-> positions_duplicate: ERRORE: " + err);
            }
        } else {
            console.log("-> positions_duplicate: SKIP (nessuna coordinata disponibile)");
        }

        // ── 3. ACTIVITIES ────────────────────────────────────────────────────
        try {
            // Cerca sessione attiva per questa board
            let activeActivity = null;
            try {
                const active = e.app.findRecordsByFilter(
                    "activities",
                    "board_id = {:boardId} && is_active = true",
                    "-created", 1, 0,
                    { "boardId": boardId }
                );
                if (active.length > 0) activeActivity = active[0];
            } catch (_) {
                // Nessuna sessione attiva — activeActivity resta null
            }

            if (!sleep) {
                // ── Dispositivo SVEGLIO ──────────────────────────────────────
                if (activeActivity) {
                    // Sessione già aperta: aggiorna steps e end_time
                    const currentSteps = activeActivity.getInt("total_steps");
                    activeActivity.set("total_steps", currentSteps + steps);
                    activeActivity.set("end_time", timestamp);
                    e.app.save(activeActivity);
                    console.log("-> activities UPDATE (steps tot: " + (currentSteps + steps) + "): OK");

                } else {
                    // Nessuna sessione attiva: anti-duplicazione
                    // Controlla se ne esiste già una chiusa da meno di SESSION_DEDUP_SEC
                    let tooRecent = false;
                    try {
                        const recentClosed = e.app.findRecordsByFilter(
                            "activities",
                            "board_id = {:boardId} && is_active = false",
                            "-created", 1, 0,
                            { "boardId": boardId }
                        );
                        if (recentClosed.length > 0) {
                            const closedAt  = new Date(recentClosed[0].getString("end_time"));
                            const nowTs     = new Date(timestamp);
                            const diffSec   = (nowTs - closedAt) / 1000;
                            tooRecent = diffSec < SESSION_DEDUP_SEC;
                            if (tooRecent) {
                                console.log("-> activities: sessione chiusa da " + Math.round(diffSec) + "s — deduplicazione, no nuova sessione.");
                            }
                        }
                    } catch (_) {}

                    if (!tooRecent) {
                        const col = e.app.findCollectionByNameOrId("activities");
                        const rec = new Record(col);
                        rec.set("board_id",    boardId);
                        rec.set("total_steps", steps);
                        rec.set("start_time",  timestamp);
                        rec.set("end_time",    null);
                        rec.set("is_active",   true);
                        rec.set("anomaly",     false);
                        e.app.save(rec);
                        console.log("-> activities CREATE nuova sessione: OK");
                    }
                }

            } else {
                // ── Dispositivo in SLEEP → chiudi sessione attiva ────────────
                if (activeActivity) {
                    activeActivity.set("end_time", timestamp);
                    activeActivity.set("is_active", false);
                    e.app.save(activeActivity);
                    console.log("-> activities CHIUSURA sessione: OK");
                } else {
                    console.log("-> activities: sleep=true ma nessuna sessione attiva, nulla da fare.");
                }
            }

        } catch (err) {
            console.log("-> activities: ERRORE: " + err);
        }

        // ── 4. EVENTO: rete ripristinata ─────────────────────────────────────
        if (netFailCount > 0) {
            salvaEvento(e.app, boardId, "net_restored",
                "Irraggiungibile per " + netFailCount + " boot consecutivi");
        }

        // ── 5. EVENTO: GPS perso (solo al raggiungimento esatto della soglia) ─
        if (!gpsValid && gpsFailCount === GPS_FAIL_ALERT_THRESH) {
            salvaEvento(e.app, boardId, "gps_lost",
                "Nessun fix GPS per " + gpsFailCount + " pacchetti consecutivi");
        }

        // ── 6. EVENTO: GPS tornato disponibile ───────────────────────────────
        // FIX: controlla esplicitamente che esista un pacchetto precedente con
        // gps_valid=false, evitando falsi "gps_restored" al primo boot.
        if (gpsValid && gpsFailCount === 0) {
            try {
                const prevWithoutGps = e.app.findRecordsByFilter(
                    "data_sent_raw",
                    "board_id = {:boardId} && id != {:id} && gps_valid = false",
                    "-created", 1, 0,
                    { "boardId": boardId, "id": raw.getId() }
                );
                if (prevWithoutGps.length > 0) {
                    salvaEvento(e.app, boardId, "gps_restored", "Fix GPS tornato disponibile");
                }
            } catch (_) {}
        }

    } finally {
        // Garantisce sempre la propagazione dell'evento nella chain di PocketBase
        e.next();
    }

}, "data_sent_raw");


// ═══════════════════════════════════════════════════════════════
//  CRON: Watchdog silenzio dispositivo
//  Ogni minuto controlla se una sessione attiva è ferma da troppo.
//  Se sì: la chiude come anomalia e salva un evento in device_events.
// ═══════════════════════════════════════════════════════════════
cronAdd("watchdog_device_silence", "* * * * *", () => {

    const TIMEOUT_MS = WATCHDOG_TIMEOUT_MIN * 60 * 1000;
    const now        = new Date();

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

            if (elapsed < TIMEOUT_MS) return; // Dispositivo ancora attivo, nulla da fare

            console.log("[WATCHDOG] " + boardId + " silenziosa da " + elapsedMin + " min. Chiusura sessione.");

            try {
                activity.set("is_active", false);
                activity.set("end_time",  now.toISOString());
                activity.set("anomaly",   true);
                $app.save(activity);
                console.log("[WATCHDOG] Sessione chiusa come anomalia per board " + boardId);
            } catch (saveErr) {
                console.log("[WATCHDOG] Errore chiusura sessione per board " + boardId + ": " + saveErr);
            }

            salvaEvento($app, boardId, "watchdog",
                "Nessun pacchetto da " + elapsedMin + " minuti");
        });

    } catch (err) {
        console.log("[WATCHDOG] Errore generale: " + err);
    }

});