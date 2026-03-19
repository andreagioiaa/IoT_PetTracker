import getpass
import random
import datetime
from pocketbase import PocketBase

def migration_v36():
    url = "https://harvey-chairless-shenna.ngrok-free.dev"
    print(f"--- PocketBase Manager (Cormons Base) ---")
    email = input("Email admin: ")
    password = getpass.getpass("Password admin: ")

    pb = PocketBase(url)

    try:
        pb.admins.auth_with_password(email, password)
        print("✅ Autenticato con successo.")

        # --- FUNZIONE COPIA ESISTENTE ---
        def copy_data(source_name, target_name):
            print(f"\n📦 Migrazione: {source_name} -> {target_name}")
            response = pb.send(f"/api/collections/{source_name}/records", {
                "method": "GET",
                "params": {"perPage": 500}
            })
            raw_records = response.get('items', [])
            if not raw_records:
                print(f"   ℹ️ Nessun record trovato in {source_name}.")
                return

            count = 0
            for record_dict in raw_records:
                data_to_send = record_dict.copy()
                for key in ['created', 'updated', 'collectionId', 'collectionName']:
                    data_to_send.pop(key, None)
                try:
                    pb.send(f"/api/collections/{target_name}/records", {"method": "POST", "body": data_to_send})
                    count += 1
                except:
                    pass 
            print(f"✨ Migrazione completata: {count}/{len(raw_records)} record.")

        # --- FUNZIONE GEOFENCING (Fittizi) ---
        def popolazione_fittizi_geofencing(target_name="geofences_test", count=3):
            print(f"\n🌍 Generazione Geofencing fittizi in {target_name}...")
            # Coordinate base Cormons
            base_lat, base_lon = 45.960, 13.470 
            
            for i in range(count):
                lat = base_lat + random.uniform(-0.01, 0.01)
                lon = base_lon + random.uniform(-0.01, 0.01)
                radius = random.choice([100, 250, 500, 1000])
                
                # Assumo campi: name, lat, lon, radius (adattali se diversi)
                data = {
                    "name": f"Zona Test {chr(65+i)}",
                    "lat": lat,
                    "lon": lon,
                    "radius": radius
                }
                try:
                    pb.send(f"/api/collections/{target_name}/records", {"method": "POST", "body": data})
                except Exception as e:
                    print(f"   ❌ Errore geofence {i}: {e}")
            print(f"✨ Creati {count} geofences fittizi.")

        # --- FUNZIONE POSITIONS (Fittizi con movimento) ---
        def popolazione_fittizi_positions(target_name="positions_test", count=10):
            print(f"\n📍 Generazione Positions fittizie in {target_name}...")
            # Punto di partenza: Cormons
            curr_lat, curr_lon = 45.960, 13.470
            curr_time = datetime.datetime.now()

            for i in range(count):
                # Simuliamo un movimento lineare/casuale
                curr_lat += random.uniform(-0.0005, 0.0005)
                curr_lon += random.uniform(-0.0005, 0.0005)
                curr_time += datetime.timedelta(minutes=random.randint(2, 10))
                
                data = {
                    "timestamp": curr_time.strftime('%Y-%m-%d %H:%M:%S.000Z'),
                    "lat": curr_lat,
                    "lon": curr_lon,
                    "geo": f"{curr_lon}, {curr_lat}",
                    "battery": random.randint(15, 95)
                }
                try:
                    pb.send(f"/api/collections/{target_name}/records", {"method": "POST", "body": data})
                except Exception as e:
                    print(f"   ❌ Errore posizione {i}: {e}")
            print(f"✨ Create {count} posizioni fittizie.")

        # --- WORKFLOW ---
        # 1. Copia dati reali
        # copy_data("geofences", "geofences_test")
        # copy_data("positions", "positions_test")

        # 2. Aggiungi dati fittizi
        popolazione_fittizi_geofencing(count=20)
        popolazione_fittizi_positions(count=20)

        print("\n🚀 Ambiente di test completato con successo.")

    except Exception as e:
        print(f"🛑 Errore critico: {e}")

if __name__ == "__main__":
    migration_v36()