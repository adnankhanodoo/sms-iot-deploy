#!/usr/bin/env python3
import sys, json, time, urllib.request, urllib.parse, ssl, os

DEVICE_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.51.4"
BASE_URL = f"https://{DEVICE_IP}"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def get_admin_token():
    data = urllib.parse.urlencode({
        "grant_type": "password", "client_id": "admin-cli",
        "username": "admin", "password": "secret"
    }).encode()
    r = urllib.request.Request(f"{BASE_URL}/auth/realms/master/protocol/openid-connect/token", data=data, method="POST")
    with urllib.request.urlopen(r, context=ctx, timeout=10) as res:
        return json.loads(res.read())["access_token"]

def create_service_user(admin_token):
    h = {"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json"}
    client = {"clientId": "sms-import", "enabled": True, "serviceAccountsEnabled": True, "standardFlowEnabled": False, "directAccessGrantsEnabled": False}
    r = urllib.request.Request(f"{BASE_URL}/auth/admin/realms/master/clients", data=json.dumps(client).encode(), method="POST", headers=h)
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=10) as res:
            return res.headers.get("Location", "").split("/")[-1]
    except urllib.error.HTTPError as e:
        if e.code == 409:
            r2 = urllib.request.Request(f"{BASE_URL}/auth/admin/realms/master/clients?clientId=sms-import", headers=h)
            with urllib.request.urlopen(r2, context=ctx, timeout=10) as res:
                return json.loads(res.read())[0]["id"]
        raise

def get_client_secret(admin_token, client_uuid):
    h = {"Authorization": f"Bearer {admin_token}"}
    r = urllib.request.Request(f"{BASE_URL}/auth/admin/realms/master/clients/{client_uuid}/client-secret", headers=h)
    with urllib.request.urlopen(r, context=ctx, timeout=10) as res:
        return json.loads(res.read())["value"]

def add_roles(admin_token, client_uuid):
    h = {"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json"}
    r = urllib.request.Request(f"{BASE_URL}/auth/admin/realms/master/clients/{client_uuid}/service-account-user", headers=h)
    with urllib.request.urlopen(r, context=ctx, timeout=10) as res:
        user_id = json.loads(res.read())["id"]
    r2 = urllib.request.Request(f"{BASE_URL}/auth/admin/realms/master/roles", headers=h)
    with urllib.request.urlopen(r2, context=ctx, timeout=10) as res:
        roles = json.loads(res.read())
    r3 = urllib.request.Request(f"{BASE_URL}/auth/admin/realms/master/users/{user_id}/role-mappings/realm", data=json.dumps(roles).encode(), method="POST", headers=h)
    try:
        with urllib.request.urlopen(r3, context=ctx, timeout=10): pass
    except: pass

def get_or_token(secret):
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": "sms-import", "client_secret": secret}).encode()
    r = urllib.request.Request(f"{BASE_URL}/auth/realms/master/protocol/openid-connect/token", data=data, method="POST")
    with urllib.request.urlopen(r, context=ctx, timeout=10) as res:
        return json.loads(res.read())["access_token"]

ASSETS_FILE = os.path.join(os.path.dirname(__file__), "assets_backup.json")
if not os.path.exists(ASSETS_FILE):
    print("No assets_backup.json found"); sys.exit(0)

with open(ASSETS_FILE) as f:
    assets = json.load(f)

print(f"Connecting to {BASE_URL}...")
admin_token = None
for i in range(20):
    try:
        admin_token = get_admin_token(); break
    except:
        print(f"  Retry {i+1}/20..."); time.sleep(6)

if not admin_token:
    print("Auth failed"); sys.exit(1)
print("Keycloak OK")

client_uuid = create_service_user(admin_token)
print(f"Service client: {client_uuid}")
secret = get_client_secret(admin_token, client_uuid)
add_roles(admin_token, client_uuid)
time.sleep(2)
or_token = get_or_token(secret)
print("OpenRemote API authenticated")

skip = ["ConsoleAsset", "MQTTAgent"]
created = 0
for asset in assets:
    if asset.get("type") in skip: continue
    for f in ["id", "createdOn", "version"]: asset.pop(f, None)
    name = asset.get("name", "?")
    h = {"Authorization": f"Bearer {or_token}", "Content-Type": "application/json", "Accept": "application/json"}
    r = urllib.request.Request(f"{BASE_URL}/api/master/asset", data=json.dumps(asset).encode(), method="POST", headers=h)
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=15) as res:
            result = json.loads(res.read())
            created += 1
            print(f"  Created: {name} -> {result.get('id')}")
    except Exception as e:
        print(f"  Failed: {name} -> {e}")

print(f"Done: {created} assets created")
