#!/usr/bin/env python3
import sys
DEVICE_IP=sys.argv[1]; OR_HOSTNAME=sys.argv[2]
FRIGATE=sys.argv[3].lower() in ('y','yes'); ZIGBEE=sys.argv[4].lower() in ('y','yes')

compose=f"""services:
  proxy:
    image: openremote/proxy:latest
    container_name: smarthome-proxy
    restart: always
    depends_on: [manager]
    ports: ["80:80","443:443","8883:8883"]
    environment:
      - OR_HOSTNAME={OR_HOSTNAME}
      - OR_SSL_PORT=443
    volumes:
      - proxy-data:/deployment
      - ./ssl/shared.pem:/etc/haproxy/certs/iot.pem
  postgresql:
    image: openremote/postgresql:latest
    container_name: smarthome-postgresql
    restart: always
    environment: [POSTGRES_PASSWORD=postgres]
    volumes: [postgresql-data:/var/lib/postgresql/data]
  keycloak:
    image: openremote/keycloak:latest
    container_name: smarthome-keycloak
    restart: always
    depends_on: [postgresql]
    environment:
      - KEYCLOAK_ADMIN=admin
      - KEYCLOAK_ADMIN_PASSWORD=secret
      - KEYCLOAK_ISSUER_BASE_URI=https://{OR_HOSTNAME}/auth
      - KC_HOSTNAME=
      - KC_HOSTNAME_STRICT=false
    volumes: [keycloak-data:/opt/keycloak/data/h2]
  manager:
    image: openremote/manager:latest
    container_name: smarthome-manager
    restart: always
    depends_on: [keycloak,postgresql]
    environment:
      - OR_HOSTNAME={OR_HOSTNAME}
      - OR_SSL_PORT=443
      - KEYCLOAK_SERVER_URL=http://keycloak:8080
      - KEYCLOAK_REALM=openremote
      - OR_ADD_MANAGED_KEYCLOAK=false
      - OR_WEBSERVER_ALLOWED_ORIGINS=*
    volumes: [manager-data:/storage]
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: always
    ports: ["1883:1883"]
    volumes:
      - ./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf
      - mosquitto-data:/mosquitto/data
  frigate-nginx:
    image: nginx:alpine
    container_name: frigate-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx/frigate-nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
"""
if ZIGBEE:
    compose+="""  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:latest
    container_name: zigbee2mqtt
    restart: always
    user: "0:0"
    ports: ["8082:8082"]
    volumes:
      - ./zigbee2mqtt-data:/app/data
      - /run/udev:/run/udev:ro
    devices: [/dev/ttyUSB0:/dev/ttyUSB0]
    depends_on: [mosquitto]
"""
if FRIGATE:
    compose+="""  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    restart: unless-stopped
    privileged: true
    shm_size: "512mb"
    ports: ["5000:5000","8971:8971","1935:1935","8554:8554","1984:1984","8555:8555","8555:8555/udp"]
    volumes:
      - ./frigate/config:/config
      - /media/frigate:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    devices:
      - /dev/bus/usb:/dev/bus/usb
      - /dev/dri:/dev/dri
"""
compose+="""  event-queue:
    build: ./event-queue
    container_name: sms-event-queue
    restart: always
    network_mode: host
    volumes:
      - ./event-queue/event_queue.py:/app/event_queue.py
"""
compose+="""volumes:
  proxy-data:
  manager-data:
  postgresql-data:
  keycloak-data:
  mosquitto-data:
"""
with open("docker-compose.yml","w") as f: f.write(compose)
print(f"docker-compose.yml generated (Frigate={FRIGATE}, Zigbee={ZIGBEE})")
