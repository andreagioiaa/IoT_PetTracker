const admin = require("firebase-admin");
const express = require("express");
const serviceAccount = require("./service-account.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const app = express();
app.use(express.json());

app.post("/send", async (req, res) => {
  const { token, title, body } = req.body;
  
  const message = {
    notification: { title, body },
    token: token
  };

  try {
    const response = await admin.messaging().send(message);
    console.log("Notifica inviata con successo:", response);
    res.status(200).json({ success: true, response });
  } catch (error) {
    console.error("Errore FCM rilevato:", error.code);

    // Mappatura degli errori Firebase verso codici HTTP standard
    switch (error.code) {
      case "messaging/registration-token-not-registered":
      case "messaging/invalid-registration-token":
        // L'app è stata disinstallata o il token è scaduto
        res.status(404).json({ error: "Token non più valido", code: error.code });
        break;

      case "messaging/invalid-argument":
      case "messaging/invalid-payload":
        // Errore nel formato dei dati inviati
        res.status(400).json({ error: "Argomento non valido", code: error.code });
        break;

      case "messaging/message-rate-exceeded":
        // Troppi messaggi inviati (Quota exceeded)
        res.status(429).json({ error: "Quota superata", code: error.code });
        break;

      default:
        // Altri errori interni di Firebase o di rete
        res.status(500).json({ error: error.message, code: error.code });
        break;
    }
  }
});

app.listen(3000, () => {
  console.log("FCM Bridge evoluto attivo su http://localhost:3000");
});