import paho.mqtt.client as mqtt
import json
import queue
import threading
import time
import requests
import os
import glob

event_queue = queue.Queue()
BROKER = "localhost"
PORT = 1883
SOURCE_TOPIC = "frigate-165/events"
CAMERAS = ["cam242", "cam243"]
PERSON_LABELS = ["person"]
ANIMAL_LABELS = ["animal", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe"]
FRIGATE_URL = "http://localhost:5000"
CLOUD_BASE = "http://100.84.164.127:8181/api/events"
UPLOAD_URL = "https://portal.smsiotpk.com/sms-api/upload"
LOGIN_URL = "https://portal.smsiotpk.com/sms-api/auth/login"
CLOUD_USER = "sms"
CLOUD_PASS = "SmsIoT@2026"
PENDING_DIR = "/tmp/pending_uploads"

os.makedirs(PENDING_DIR, exist_ok=True)

active_persons = {"cam242": {}, "cam243": {}}
_token_cache = {"token": None, "expires": 0}

def get_auth_token():
    if _token_cache["token"] and time.time() < _token_cache["expires"] - 60:
        return _token_cache["token"]
    try:
        r = requests.post(LOGIN_URL,
            json={"username": CLOUD_USER, "password": CLOUD_PASS},
            timeout=10)
        token = r.json().get("token")
        _token_cache["token"] = token
        _token_cache["expires"] = time.time() + 86400
        print("🔑 Token refreshed")
        return token
    except Exception as e:
        print(f"Auth error: {e}")
        return None

def upload_file(local_path, filename, token):
    try:
        with open(local_path, "rb") as f:
            r = requests.post(UPLOAD_URL,
                headers={"Authorization": f"Bearer {token}"},
                files={"file": (filename, f)},
                timeout=120)
        if r.status_code == 200:
            ext = "clip.mp4" if filename.endswith(".mp4") else "snapshot.jpg"
            eid = filename.replace(".mp4", "").replace(".jpg", "")
            return f"{CLOUD_BASE}/{eid}/{ext}"
        print(f"Upload failed: {r.status_code}")
        return None
    except Exception as e:
        print(f"Upload error: {e}")
        return None

def save_pending(event_id, camera, clip_path, snap_path, event_meta):
    pending_file = os.path.join(PENDING_DIR, f"{event_id}.json")
    with open(pending_file, "w") as f:
        json.dump({
            "event_id": event_id,
            "camera": camera,
            "clip_path": clip_path,
            "snap_path": snap_path,
            "meta": event_meta,
            "queued_at": time.time()
        }, f)
    print(f"💾 Saved pending: {event_id[:20]}")

def try_upload_pending(client):
    while True:
        pending_files = glob.glob(os.path.join(PENDING_DIR, "*.json"))
        for pf in pending_files:
            try:
                with open(pf) as f:
                    p = json.load(f)
                event_id = p["event_id"]
                camera = p["camera"]
                clip_path = p["clip_path"]
                snap_path = p["snap_path"]
                meta = p["meta"]

                if not os.path.exists(clip_path):
                    print(f"⚠️ Clip missing: {event_id[:20]} — removing")
                    os.remove(pf)
                    continue

                print(f"🔄 Retrying: {event_id[:20]}")
                token = get_auth_token()
                if not token:
                    break

                clip_name = os.path.basename(clip_path)
                snap_name = os.path.basename(snap_path)
                clip_url = upload_file(clip_path, clip_name, token)
                snap_url = upload_file(snap_path, snap_name, token) if os.path.exists(snap_path) else None

                if clip_url:
                    topic_group = "person" if meta["label"] in PERSON_LABELS else "animal"
                    topic = f"frigate-165/{camera}/{topic_group}/event"
                    event = [{
                        "id": meta["id"],
                        "label": meta["label"],
                        "camera": camera,
                        "start_time": meta["start_time"],
                        "end_time": meta["end_time"],
                        "clip_url": clip_url,
                        "snapshot_url": snap_url or ""
                    }]
                    client.publish(topic, json.dumps(event), qos=1, retain=False)
                    print(f"✅ Retry success: {event_id[:20]}")
                    os.remove(pf)
                    if os.path.exists(clip_path): os.remove(clip_path)
                    if snap_path and os.path.exists(snap_path): os.remove(snap_path)
                else:
                    print(f"⏳ Retry failed — will try again: {event_id[:20]}")

            except Exception as e:
                print(f"Pending error: {e}")

        time.sleep(30)

def download_and_upload(event_id, camera, after):
    try:
        clip_resp = requests.get(
            f"{FRIGATE_URL}/api/events/{event_id}/clip.mp4",
            timeout=60, stream=True)
        snap_resp = requests.get(
            f"{FRIGATE_URL}/api/events/{event_id}/snapshot.jpg",
            timeout=10)

        if clip_resp.status_code != 200:
            print(f"Clip not ready: {event_id}")
            return None, None

        clip_name = f"{event_id}.mp4"
        snap_name = f"{event_id}.jpg"
        clip_tmp = os.path.join(PENDING_DIR, clip_name)
        snap_tmp = os.path.join(PENDING_DIR, snap_name)

        with open(clip_tmp, "wb") as f:
            for chunk in clip_resp.iter_content(8192):
                f.write(chunk)
        with open(snap_tmp, "wb") as f:
            f.write(snap_resp.content)

        print(f"📥 Downloaded: {os.path.getsize(clip_tmp)} bytes")

        token = get_auth_token()
        clip_url = upload_file(clip_tmp, clip_name, token) if token else None
        snap_url = upload_file(snap_tmp, snap_name, token) if token else None

        if clip_url:
            os.remove(clip_tmp)
            os.remove(snap_tmp)
            return clip_url, snap_url
        else:
            print(f"📡 No internet — saving to pending queue")
            save_pending(event_id, camera, clip_tmp, snap_tmp, {
                "id": event_id,
                "label": after["label"],
                "start_time": after["start_time"],
                "end_time": after["end_time"]
            })
            return None, None

    except Exception as e:
        print(f"Download/upload error: {e}")
        return None, None

def on_connect(client, userdata, flags, rc):
    print(f"Connected rc={rc}")
    client.subscribe(SOURCE_TOPIC, qos=1)

def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload)
        after = payload.get("after", {})
        event_type = payload.get("type")
        camera = after.get("camera")
        label = after.get("label")
        person_id = after.get("id")

        if camera not in CAMERAS or (label not in PERSON_LABELS and label not in ANIMAL_LABELS):
            return

        topic_group = "person" if label in PERSON_LABELS else "animal"

        if event_type == "new":
            active_persons[camera][person_id] = after["start_time"]
            count = len(active_persons[camera])
            client.publish(f"frigate-165/{camera}/{topic_group}/active",
                str(count), qos=1, retain=True)
            print(f"🟢 {camera}: {label} entered | active={count}")

        elif event_type == "end":
            active_persons[camera].pop(person_id, None)
            count = len(active_persons[camera])
            client.publish(f"frigate-165/{camera}/{topic_group}/active",
                str(count), qos=1, retain=True)
            print(f"🔴 {camera}: {label} left | active={count}")
            event_queue.put((camera, after))
            print(f"Queued {camera}: {person_id[:20]}")

    except Exception as e:
        print(f"Error: {e}")

def process_queue(client):
    while True:
        try:
            camera, after = event_queue.get(timeout=5)
            person_id = after["id"]
            time.sleep(3)
            print(f"⬇️  Downloading clip for {person_id[:20]}...")
            clip_url, snap_url = download_and_upload(person_id, camera, after)

            # Always publish — with or without clip
            topic_group = "person" if after["label"] in PERSON_LABELS else "animal"
            topic = f"frigate-165/{camera}/{topic_group}/event"
            event = [{
                "id": person_id,
                "label": after["label"],
                "camera": camera,
                "start_time": after["start_time"],
                "end_time": after["end_time"]
            }]
            client.publish(topic, json.dumps(event), qos=1, retain=False)
            print(f"✅ Published → {topic} | clip:{clip_url}")
            time.sleep(1)

        except queue.Empty:
            continue
        except Exception as e:
            print(f"Process error: {e}")
            time.sleep(3)

client = mqtt.Client(client_id="sms-event-queue")
client.on_connect = on_connect
client.on_message = on_message

while True:
    try:
        client.connect(BROKER, PORT, 60)
        break
    except Exception as e:
        print(f"Broker not ready: {e}, retrying...")
        time.sleep(5)

threading.Thread(target=process_queue, args=(client,), daemon=True).start()
threading.Thread(target=try_upload_pending, args=(client,), daemon=True).start()
print("SMS Event Queue running...")
client.loop_forever()
