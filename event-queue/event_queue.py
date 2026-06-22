import paho.mqtt.client as mqtt
import json
import queue
import threading
import time
import requests
import os
import glob
import urllib3
urllib3.disable_warnings()

BROKER        = "localhost"
PORT          = 1883
SOURCE_TOPIC  = "frigate-165/events"
CAMERAS       = ["cam242", "cam243"]
PERSON_LABELS = ["person"]
ANIMAL_LABELS = ["animal", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe"]
FRIGATE_URL   = "http://localhost:5000"
UPLOAD_URL    = "https://100.84.164.127:8181/api/upload"
UPLOAD_SECRET = "SmsIoT2026SecretKey"
CLOUD_BASE    = "https://100.84.164.127:8181/api/events"
PENDING_DIR   = "/tmp/pending_uploads"
CLIP_BEFORE   = 13
CLIP_AFTER    = 13
MIN_CLIP_SECONDS = 10      # if downloaded clip is shorter than this, retry the download
DOWNLOAD_RETRIES = 2
DOWNLOAD_RETRY_WAIT = 3    # seconds between download retries (lets Frigate finish buffering)

os.makedirs(PENDING_DIR, exist_ok=True)
event_queue    = queue.Queue()
active_persons = {"cam242": {}, "cam243": {}}


def upload_file(local_path, filename, camera=""):
    try:
        with open(local_path, "rb") as f:
            r = requests.post(UPLOAD_URL, headers={"X-Auth": UPLOAD_SECRET},
                files={"file": (filename, f)}, data={"camera": camera},
                verify=False, timeout=120)
        if r.status_code == 200:
            ext = "clip.mp4" if filename.endswith(".mp4") else "snapshot.jpg"
            eid = filename.replace(".mp4", "").replace(".jpg", "")
            return f"{CLOUD_BASE}/{eid}/{ext}"
        print(f"Upload failed: {r.status_code} — {r.text[:100]}")
        return None
    except Exception as e:
        print(f"Upload error: {e}")
        return None


def save_pending(event_id, camera, clip_path, snap_path, meta):
    pf = os.path.join(PENDING_DIR, f"{event_id}.json")
    with open(pf, "w") as f:
        json.dump({"event_id": event_id, "camera": camera, "clip_path": clip_path,
                   "snap_path": snap_path, "meta": meta, "queued_at": time.time()}, f)
    print(f"💾 Saved pending: {event_id[:20]}")


def try_upload_pending(client):
    while True:
        for pf in glob.glob(os.path.join(PENDING_DIR, "*.json")):
            try:
                with open(pf) as f:
                    content_raw = f.read().strip()
                if not content_raw:
                    print(f"🗑️ Removing empty pending file: {pf}")
                    os.remove(pf)
                    continue
                try:
                    p = json.loads(content_raw)
                except json.JSONDecodeError:
                    print(f"🗑️ Removing corrupt pending file: {pf}")
                    os.remove(pf)
                    continue
                clip_path = p["clip_path"]
                snap_path = p["snap_path"]
                if not os.path.exists(clip_path):
                    os.remove(pf)
                    continue
                print(f"🔄 Retrying upload: {p['event_id'][:20]}")
                _cam = p.get("camera", "")
                clip_url = upload_file(clip_path, os.path.basename(clip_path), _cam)
                snap_url = upload_file(snap_path, os.path.basename(snap_path), _cam) if snap_path and os.path.exists(snap_path) else None
                if clip_url:
                    print(f"✅ Retry upload OK: {p['event_id'][:20]}")
                    os.remove(pf)
                    if os.path.exists(clip_path): os.remove(clip_path)
                    if snap_path and os.path.exists(snap_path): os.remove(snap_path)
                else:
                    print(f"⏳ Retry upload failed, will try again: {p['event_id'][:20]}")
            except Exception as e:
                print(f"Pending error: {e}")
        time.sleep(30)


def download_clip_once(camera, start, end, event_id):
    """Single attempt to download the padded clip from Frigate."""
    clip_resp = requests.get(
        f"{FRIGATE_URL}/api/{camera}/start/{start}/end/{end}/clip.mp4",
        timeout=60, stream=True
    )
    if clip_resp.status_code != 200:
        return None, clip_resp.status_code

    clip_tmp = os.path.join(PENDING_DIR, f"{event_id}.mp4")
    with open(clip_tmp, "wb") as f:
        for chunk in clip_resp.iter_content(8192):
            f.write(chunk)
    return clip_tmp, 200


def get_local_duration_seconds(filepath):
    """Quick duration check using file size heuristic avoided —
    use ffprobe for accuracy since it's already installed system-wide."""
    try:
        import subprocess
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "csv=p=0", filepath],
            capture_output=True, text=True, timeout=10
        )
        return float(result.stdout.strip())
    except Exception:
        return 0


def download_and_upload(event_id, camera, after):
    """
    Downloads the padded clip + snapshot from Frigate, then uploads to cloud.
    Retries the DOWNLOAD (not just the upload) if Frigate hasn't finished
    buffering the post-event footage yet — this fixes the short/truncated
    clip bug where the very first download attempt happens before Frigate
    has written the full +CLIP_AFTER segment to disk.
    """
    try:
        start = max(0, after["start_time"] - CLIP_BEFORE)
        end   = after["end_time"] + CLIP_AFTER
        expected_seconds = end - start
        print(f"✂️  Clipping {camera} {start:.1f}→{end:.1f} (~{expected_seconds:.0f}s expected)")

        clip_tmp = None
        for attempt in range(1, DOWNLOAD_RETRIES + 1):
            clip_tmp, status = download_clip_once(camera, start, end, event_id)
            if clip_tmp is None:
                print(f"Clip not ready (status={status}), attempt {attempt}/{DOWNLOAD_RETRIES}")
                time.sleep(DOWNLOAD_RETRY_WAIT)
                continue

            actual_seconds = get_local_duration_seconds(clip_tmp)
            print(f"📥 Download attempt {attempt}: {os.path.getsize(clip_tmp)} bytes, "
                  f"{actual_seconds:.1f}s (expected ~{expected_seconds:.0f}s)")

            # Accept if close enough to expected, or if it's the last attempt
            if actual_seconds >= min(MIN_CLIP_SECONDS, expected_seconds - 2) or attempt == DOWNLOAD_RETRIES:
                break

            print(f"⚠️  Clip shorter than expected — Frigate may still be buffering, retrying download...")
            time.sleep(DOWNLOAD_RETRY_WAIT)

        if clip_tmp is None:
            print(f"❌ Could not download clip after {DOWNLOAD_RETRIES} attempts: {event_id}")
            return None, None

        snap_resp = requests.get(f"{FRIGATE_URL}/api/events/{event_id}/snapshot.jpg", timeout=10)
        snap_tmp = os.path.join(PENDING_DIR, f"{event_id}.jpg")
        with open(snap_tmp, "wb") as f:
            f.write(snap_resp.content)

        clip_name = f"{event_id}.mp4"
        snap_name = f"{event_id}.jpg"
        clip_url = upload_file(clip_tmp, clip_name, camera)
        snap_url = upload_file(snap_tmp, snap_name, camera)

        if clip_url:
            os.remove(clip_tmp)
            if os.path.exists(snap_tmp): os.remove(snap_tmp)
            return clip_url, snap_url
        else:
            print(f"📡 Upload failed — saving pending for background retry")
            save_pending(event_id, camera, clip_tmp, snap_tmp, {
                "id": event_id, "label": after["label"],
                "start_time": after["start_time"], "end_time": after["end_time"]
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
        payload    = json.loads(msg.payload)
        after      = payload.get("after", {})
        event_type = payload.get("type")
        camera     = after.get("camera")
        label      = after.get("label")
        person_id  = after.get("id")

        if camera not in CAMERAS:
            return
        if label not in PERSON_LABELS and label not in ANIMAL_LABELS:
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
            # Publish the "active count" — this is what OpenRemote's is_person/is_animal
            # attribute should subscribe to. Publishing it HERE, immediately on "end",
            # means it always fires together (same MQTT batch) as the queued event.
            client.publish(f"frigate-165/{camera}/{topic_group}/active",
                            str(count), qos=1, retain=True)
            print(f"🔴 {camera}: {label} left | active={count}")
            event_queue.put((camera, after))
            print(f"Queued {camera}: {person_id[:20]}")
    except Exception as e:
        print(f"on_message error: {e}")


def process_queue(client):
    """
    Publishes the eventId (with id/camera/start_time/end_time) IMMEDIATELY,
    in the SAME step as the is_person/is_animal "active" signal, so OpenRemote
    receives both attribute updates close together and the rule reliably fires.
    The actual clip download+upload happens AFTER publishing, in the background,
    so the dashboard alert is never delayed waiting for the cloud upload.
    """
    while True:
        try:
            camera, after = event_queue.get(timeout=5)
            person_id   = after["id"]
            label       = after["label"]
            topic_group = "person" if label in PERSON_LABELS else "animal"

            # 1) Publish the event immediately (id/camera/start_time/end_time)
            #    This is what OpenRemote's eventId attribute subscribes to.
            event_topic = f"frigate-165/{camera}/{topic_group}/event"
            event_payload = [{
                "id": person_id, "label": label, "camera": camera,
                "start_time": after["start_time"], "end_time": after["end_time"]
            }]
            client.publish(event_topic, json.dumps(event_payload), qos=1, retain=False)

            # 2) ALWAYS publish "0" for THIS specific leave event, regardless of
            #    how many other people/animals are still active in frame.
            #    This is intentional — every eventId update must be paired with
            #    its own is_person=0 signal so the OpenRemote rule reliably fires
            #    per-event, not based on the real-time active headcount.
            client.publish(f"frigate-165/{camera}/{topic_group}/active",
                            "0", qos=1, retain=True)

            print(f"✅ Published event+person=0 → {camera} ({person_id[:20]})")

            # 3) Now do the slower download+upload work in the background.
            #    The MQTT/alarm side is already done — this just fills in the clip URL.
            print(f"⬇️  Downloading clip for {person_id[:20]}...")
            clip_url, snap_url = download_and_upload(person_id, camera, after)
            print(f"📦 Background upload done: clip={clip_url}")

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

threading.Thread(target=process_queue,      args=(client,), daemon=True).start()
threading.Thread(target=try_upload_pending, args=(client,), daemon=True).start()
print("SMS Event Queue running...")
client.loop_forever()
