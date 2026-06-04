#!/usr/bin/env python3
import sys, json, urllib.request, urllib.parse, ssl

DEVICE_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.51.199"
BASE_URL = f"https://{DEVICE_IP}"
REALM = "openremote"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def get_token():
    data = urllib.parse.urlencode({
        "grant_type": "password", "client_id": "openremote",
        "username": "admin", "password": "secret"
    }).encode()
    req = urllib.request.Request(f"{BASE_URL}/auth/realms/master/protocol/openid-connect/token", data=data, method="POST")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.loads(r.read())["access_token"]

def api_get(token, path):
    req = urllib.request.Request(f"{BASE_URL}/api/{REALM}/{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.loads(r.read())

print(f"Exporting assets from {BASE_URL}...")
token = get_token()
print("Authenticated")
assets = api_get(token, "asset?recursive=true")
print(f"Found {len(assets)} assets")

exportable = []
for asset in assets:
    for field in ["createdOn", "version", "accessPublicRead"]:
        asset.pop(field, None)
    exportable.append(asset)
    print(f"  Exporting: {asset.get('name')} ({asset.get('type')})")

output_file = "/home/admin/sms-iot/openremote/assets_backup.json"
with open(output_file, "w") as f:
    json.dump(exportable, f, indent=2)
print(f"\nExported {len(exportable)} assets to {output_file}")
