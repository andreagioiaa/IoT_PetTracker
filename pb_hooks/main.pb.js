onRecordAfterCreateSuccess((e) => {
    const raw = e.record;
    const boardId = raw.getString("board_id");
    const timestamp = raw.getString("timestamp");
    const sleep = raw.getBool("sleep");
    const steps = raw.getInt("steps");

    console.log("--- SMISTAMENTO AVVIATO PER BOARD: " + boardId + " | sleep: " + sleep + " | steps: " + steps + " ---");

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
    try {
        const positionsCollection = e.app.findCollectionByNameOrId("positions_duplicate");
        const positionsRecord = new Record(positionsCollection);
        positionsRecord.set("board_id", boardId);
        positionsRecord.set("timestamp", timestamp);
        positionsRecord.set("lon", raw.getFloat("lon"));
        positionsRecord.set("lat", raw.getFloat("lat"));
        positionsRecord.set("geo", raw.get("geo"));
        e.app.save(positionsRecord);
        console.log("-> positions_duplicate: OK");
    } catch (err) {
        console.log("-> positions_duplicate: ERRORE: " + err);
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
                activeActivity.set("end_time", null);
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

    e.next();

}, "data_sent_raw");

/*
routerAdd("POST", "/api/ttn-uplink", (e) => {
    try {
        const body = e.requestInfo().body;
        
        // Log di debug: stampa nel terminale di PocketBase tutto quello che arriva

        const uplink = body.uplink_message;
        if (!uplink) return e.json(400, { error: "No uplink message" });

        const payload = uplink.decoded_payload;
        if (!payload) return e.json(400, { error: "Payload non decodificato da TTN" });

        const collection = e.app.findCollectionByNameOrId("positions");
        const record = new Record(collection);

        // Identificativo dispositivo
        record.set("device_id", body.end_device_ids.device_id);

        // Coordinate (usiamo i nomi del tuo Formatted Code su TTN)
        record.set("lat", payload.latitude);
        record.set("lon", payload.longitude);

        // TIMESTAMP: Prende l'ora di ricezione da TTN
        // Se non la trova, usa l'ora attuale del server
        const ttnTime = body.received_at || new Date().toISOString();
        record.set("timestamp", ttnTime);


	    // GEO
        const geoJSON = {
            lon: parseFloat(payload.longitude),
            lat: parseFloat(payload.latitude)
        };
        
        // Passiamo l'oggetto direttamente
        record.set("geo", geoJSON);

	// BATTERIA
	record.set("battery", payload.battery_percentage)

        e.app.save(record);

        console.log("SUCCESSO: Salvato " + payload.latitude + "," + payload.longitude + " ore " + ttnTime);

        return e.json(200, { ok: true });

    } catch(err) {
        console.log("ERRORE SALVATAGGIO: " + err.message);
        return e.json(500, { error: err.message });
    }
});
*/