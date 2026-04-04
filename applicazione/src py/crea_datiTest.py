import os
import time
import random
import datetime
from dotenv import load_dotenv
from pathlib import Path
from pocketbase import PocketBase
from shapely.geometry import Polygon, Point

# --- CONFIGURAZIONE E CREDENZIALI ---
env_path = Path('.') / 'applicazione' / '.env'
load_dotenv(dotenv_path=env_path)

URL = os.getenv("PB_URL")
EMAIL = os.getenv("PB_USER")
PASSWORD = os.getenv("PB_PASS")

if not all([URL, EMAIL, PASSWORD]):
    raise ValueError("❌ Errore: Credenziali mancanti nel file .env")

# --- GEOMETRIA POLO RIZZI ---
# Definiamo il poligono globalmente per non ricrearlo a ogni ciclo (ottimizzazione)
POLO_RIZZI = [
    [46.08147551947162, 13.232251357284623],
    [46.081259893824694, 13.232491324551358],
    [46.08099280513446, 13.231519864018704],
    [46.081265077440044, 13.231377872970903]
]
POLIGONO_RIZZI = Polygon(POLO_RIZZI)

# --- FUNZIONI DI SUPPORTO ---

def check_interno(lat, lon):
    """Verifica se un punto è all'interno del Polo Rizzi."""
    punto = Point(lat, lon)
    return POLIGONO_RIZZI.intersects(punto)

def genera_punto_casuale_interno():
    """Genera un punto casuale rigorosamente dentro il perimetro."""
    min_lat, min_lon, max_lat, max_lon = POLIGONO_RIZZI.bounds
    while True:
        lat_gen = random.uniform(min_lat, max_lat)
        lon_gen = random.uniform(min_lon, max_lon)
        if check_interno(lat_gen, lon_gen):
            print("Punto interno valido!\n")
            return lat_gen, lon_gen

# --- FUNZIONI PRINCIPALI ---

def popolaDB_datiTestZoneInterni(target_collection="positions_test"):
    """La tua funzione originale: genera punti sparsi internamente."""
    pb = PocketBase(URL)
    try:
        pb.admins.auth_with_password(EMAIL, PASSWORD)
        print(f"✅ [INTERNI] Autenticato come {EMAIL}.")
        
        durata_totale = 5 * 60 
        intervallo = 20         
        cicli = durata_totale // intervallo
        livello_batteria = random.randint(70, 95)

        for i in range(cicli):
            lat, lon = genera_punto_casuale_interno()
            now = datetime.datetime.now(datetime.timezone.utc)
            
            data = {
                "timestamp": now.strftime('%Y-%m-%d %H:%M:%S.000Z'),
                "lat": lat, 
                "lon": lon,
                "geo": {
                    "lat": lat,
                    "lng": lon  # PocketBase usa 'lng' per la longitudine nel campo Map
                },
                "battery": int(livello_batteria)
            }

            pb.collection(target_collection).create(data)
            print(f"[{i+1}/{cicli}] 📍 Interno: {lat:.6f}, {lon:.6f}")
            
            livello_batteria -= random.uniform(0.1, 0.3)
            if i < cicli - 1: time.sleep(intervallo)

    except Exception as e:
        print(f"🛑 Errore critico (Interni): {e}")

def popolaDB_datiTestZoneEsterni(target_collection="positions_test"):
    """Nuova funzione: simula un percorso reale (Random Walk) all'esterno."""
    pb = PocketBase(URL)
    try:
        pb.admins.auth_with_password(EMAIL, PASSWORD)
        print(f"✅ [ESTERNI] Autenticato come {EMAIL}.")

        durata_totale = 5 * 60 
        intervallo = 20         
        cicli = durata_totale // intervallo
        
        # Punto di partenza esterno (leggermente a Nord del Polo)
        curr_lat, curr_lon = 46.0820, 13.2315
        livello_batteria = random.randint(80, 99)
        step_size = 0.00012 # Circa 10-15 metri per simulare camminata

        for i in range(cicli):
            # Cerchiamo un passo valido che non entri nel Polo Rizzi
            for _ in range(15):
                n_lat = curr_lat + random.uniform(-step_size, step_size)
                n_lon = curr_lon + random.uniform(-step_size, step_size)
                
                if not check_interno(n_lat, n_lon):
                    curr_lat, curr_lon = n_lat, n_lon
                    break
            
            now = datetime.datetime.now(datetime.timezone.utc)

            data = {
                "timestamp": now.strftime('%Y-%m-%d %H:%M:%S.000Z'),


                "lat": curr_lat, 
                "lon": curr_lon,
                
                
                "geo": {
                    "lat": curr_lat,
                    "lon": curr_lon  # PocketBase usa 'lng' per la longitudine nel campo Map
                },
                "battery": int(livello_batteria)
            }

            pb.collection(target_collection).create(data)
            print(f"[{i+1}/{cicli}] 🚶 Esterno (Percorso): {curr_lat:.6f}, {curr_lon:.6f}")
            
            livello_batteria -= random.uniform(0.1, 0.2)
            if i < cicli - 1: time.sleep(intervallo)

    except Exception as e:
        print(f"🛑 Errore critico (Esterni): {e}")

if __name__ == "__main__":
    print("--- SIMULATORE POSIZIONI POCKETBASE ---")
    print("1. Popola Interni (punti casuali nel Polo)")
    print("2. Popola Esterni (percorso reale fuori dal Polo)")
    scelta = input("Seleziona opzione (1/2): ")

    if scelta == "1":
        popolaDB_datiTestZoneInterni()
        print("✨ Missione compiuta. Dati inviati con successo.")
    elif scelta == "2":
        popolaDB_datiTestZoneEsterni()
        print("✨ Missione compiuta. Dati inviati con successo.")
    else:
        print("❌ Scelta non valida.")
