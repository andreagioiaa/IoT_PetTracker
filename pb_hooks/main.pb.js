onRecordAfterCreateRequest((e) => {
  const raw = e.record;

  // 1. Prepara e salva i dati nella collezione 'battery_data'
  const batteryCollection = $app.dao().findCollectionByNameOrId("battery_data");
  const batteryRecord = new Record(batteryCollection, {
    board_id: raw.get("board_id"),
    timestamp: raw.get("timestamp"),
    battery: raw.get("battery"),
    battery_percent: raw.get("battery_percent"),
    charging: raw.get("charging"),
  });
  $app.dao().saveRecord(batteryRecord);

  // 2. Prepara e salva i dati nella collezione 'positions'
  const positionsCollection = $app
    .dao()
    .findCollectionByNameOrId("positions_duplicate");
  const positionsRecord = new Record(positionsCollection, {
    board_id: raw.get("board_id"),
    timestamp: raw.get("timestamp"),
    lon: raw.get("lon"),
    lat: raw.get("lat"),
    geo: raw.get("geo"),
    sleep: raw.get("sleep"),
  });
  $app.dao().saveRecord(positionsRecord);

  // Nota opzionale: Se vuoi cancellare il record raw dopo averlo processato
  // per non occupare spazio inutilmente, scommenta la riga sotto:
  // $app.dao().deleteRecord(raw);
}, "data_sent_raw");

onRecordAfterCreateRequest((e) => {
  const raw = e.record;
  const boardId = raw.get("board_id");
  const isAsleep = raw.get("sleep");
  const steps = raw.get("steps") || 0;
  const timestamp = raw.get("timestamp");

  // 1. Cerchiamo se esiste un'attività già aperta (is_active = true) per questa board
  let activeActivity;
  try {
    activeActivity = $app
      .dao()
      .findFirstRecordByFilter(
        "activities",
        `board_id = "${boardId}" && is_active = true`,
      );
  } catch (err) {
    activeActivity = null;
  }

  if (!isAsleep) {
    // --- IL DISPOSITIVO È SVEGLIO ---
    if (!activeActivity) {
      // Se non c'è un'attività aperta, ne iniziamo una NUOVA
      const collection = $app.dao().findCollectionByNameOrId("activities");
      const newAct = new Record(collection, {
        board_id: boardId,
        total_steps: steps,
        start_time: timestamp,
        end_time: timestamp,
        is_active: true,
      });
      $app.dao().saveRecord(newAct);
    } else {
      // Se c'è un'attività aperta, AGGIORNIAMO i dati esistenti
      activeActivity.set(
        "total_steps",
        activeActivity.get("total_steps") + steps,
      );
      activeActivity.set("end_time", timestamp);
      $app.dao().saveRecord(activeActivity);
    }
  } else {
    // --- IL DISPOSITIVO DORME ---
    if (activeActivity) {
      // Se c'era un'attività aperta, la CHIUDIAMO
      // (Opzionale: aggiungi gli ultimi passi se il record 'true' ne contiene)
      activeActivity.set(
        "total_steps",
        activeActivity.get("total_steps") + steps,
      );
      activeActivity.set("end_time", timestamp);
      activeActivity.set("is_active", false);
      $app.dao().saveRecord(activeActivity);
    }
  }
}, "data_sent_raw");
