#!/usr/bin/env python3
import sys, json, time, urllib.request, urllib.parse, ssl, os

DEVICE_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.51.199"
BASE_URL = f"https://{DEVICE_IP}"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def get_token():
    data = urllib.parse.urlencode({'grant_type':'password','client_id':'openremote','username':'admin','password':'secret'}).encode()
    req = urllib.request.Request(f'{BASE_URL}/auth/realms/master/protocol/openid-connect/token', data=data, method='POST')
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.loads(r.read())['access_token']

def api_post(token, path, payload):
    req = urllib.request.Request(f'{BASE_URL}/api/master/{path}', data=json.dumps(payload).encode(), method='POST',
        headers={'Authorization':f'Bearer {token}','Content-Type':'application/json','Accept':'application/json'})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
            return json.loads(r.read())
    except Exception as e:
        return None

ASSETS_FILE = os.path.join(os.path.dirname(__file__), 'assets_backup.json')
if not os.path.exists(ASSETS_FILE):
    print("No assets_backup.json found"); sys.exit(0)

with open(ASSETS_FILE) as f:
    assets = json.load(f)

print(f"Waiting for OpenRemote at {BASE_URL}...")
token = None
for i in range(20):
    try:
        token = get_token(); break
    except:
        print(f"  Retry {i+1}/20..."); time.sleep(6)

if not token:
    print("Could not authenticate"); sys.exit(1)
print("Authenticated")

# Skip console/browser assets and agents (recreated automatically)
skip_types = ['ConsoleAsset', 'MQTTAgent']
created = 0
for asset in assets:
    if asset.get('type') in skip_types:
        continue
    asset.pop('id', None); asset.pop('createdOn', None); asset.pop('version', None)
    name = asset.get('name','?')
    result = api_post(token, 'asset', asset)
    if result:
        created += 1
        print(f"  Created: {name} -> {result.get('id')}")
    else:
        print(f"  Failed: {name}")

print(f"\nDone: {created} assets created")
print("Note: Manually recreate MQTT agents and update agentLink IDs")
