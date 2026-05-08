// ═══════════════════════════════════════════════════════════════
// File: bridge.js
// Bridge FCM: riceve notifiche da PocketBase e le invia a Firebase
//
// Endpoints:
//   POST /send       — singolo token (legacy, mantenuto per compatibilità)
//   POST /send-batch — array di token, parallelizzato con Promise.all
//
// Risposte /send-batch:
//   200 { results: [...], invalidTokens: [...] }
//   500 { error: "..." }
// ═══════════════════════════════════════════════════════════════

const admin          = require("firebase-admin");
const express        = require("express");
const serviceAccount = require("./service-account.json");

admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
});

const app = express();
app.use(express.json());

// ─────────────────────────────────────────────────────────────────────────────
// Codici errore FCM → codice HTTP
// ─────────────────────────────────────────────────────────────────────────────

function fcmErrorToStatus(errorCode) {
    switch (errorCode) {
        case "messaging/registration-token-not-registered":
        case "messaging/invalid-registration-token":
            return 404; // token scaduto o app disinstallata
        case "messaging/invalid-argument":
        case "messaging/invalid-payload":
            return 400; // payload malformato
        case "messaging/message-rate-exceeded":
            return 429; // quota superata
        default:
            return 500; // errore generico
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /send — singolo token (legacy)
// ─────────────────────────────────────────────────────────────────────────────

app.post("/send", async (req, res) => {
    const { token, title, body } = req.body;

    try {
        const response = await admin.messaging().send({
            notification: { title, body },
            token
        });
        console.log("[FCM] Notifica inviata:", response);
        res.status(200).json({ success: true, response });
    } catch (error) {
        console.error("[FCM] Errore:", error.code);
        const status = fcmErrorToStatus(error.code);
        res.status(status).json({ error: error.message, code: error.code });
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /send-batch — array di token, 1 chiamata HTTP da PocketBase
// ─────────────────────────────────────────────────────────────────────────────
//
// Body: { tokens: string[], title: string, body: string }
//
// Response 200:
// {
//   results: [
//     { token, success: true,  response: "..." },
//     { token, success: false, code: "messaging/..." }
//   ],
//   invalidTokens: ["token1", "token2"]  ← da rimuovere dal DB
// }
//
// ─────────────────────────────────────────────────────────────────────────────

app.post("/send-batch", async (req, res) => {
    const { tokens, title, body } = req.body;

    if (!Array.isArray(tokens) || tokens.length === 0) {
        return res.status(400).json({ error: "tokens deve essere un array non vuoto" });
    }

    try {
        // Invia tutte le notifiche in parallelo
        const results = await Promise.all(
            tokens.map(token =>
                admin.messaging()
                    .send({ notification: { title, body }, token })
                    .then(response => ({ token, success: true, response }))
                    .catch(error  => ({ token, success: false, code: error.code }))
            )
        );

        // Raccoglie i token invalidi da segnalare a PocketBase per la rimozione
        const INVALID_CODES = new Set([
            "messaging/registration-token-not-registered",
            "messaging/invalid-registration-token",
            "messaging/invalid-argument",
        ]);

        const invalidTokens = results
            .filter(r => !r.success && INVALID_CODES.has(r.code))
            .map(r => r.token);

        const successCount = results.filter(r => r.success).length;
        console.log(`[FCM BATCH] Inviati: ${successCount}/${tokens.length} | Invalidi: ${invalidTokens.length}`);

        res.status(200).json({ results, invalidTokens });

    } catch (error) {
        console.error("[FCM BATCH] Errore generale:", error);
        res.status(500).json({ error: error.message });
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// Avvio server
// ─────────────────────────────────────────────────────────────────────────────

app.listen(3000, () => {
    console.log("[BRIDGE] FCM Bridge attivo su http://localhost:3000");
});
