#!/bin/bash
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║    SMS Sentinel AI — Installer v2.0     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

# ── USER INPUT ────────────────────────────────────────────────────
read -r -p "Enter this device LAN IP (e.g. 192.168.51.211): " DEVICE_IP
read -r -p "OpenRemote hostname [default: $DEVICE_IP]: " OR_HOSTNAME
OR_HOSTNAME=${OR_HOSTNAME:-$DEVICE_IP}
read -r -p "Deploy Frigate NVR? (y/n): " DEPLOY_FRIGATE
read -r -p "Deploy Zigbee2MQTT? (y/n): " DEPLOY_ZIGBEE
read -r -p "Enable Cloud Upload? (y/n): " DEPLOY_CLOUD
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
    read -r -p "Cloud Upload URL [default: https://portal.smsiotpk.com/sms-api/upload]: " UPLOAD_URL
    UPLOAD_URL=${UPLOAD_URL:-https://portal.smsiotpk.com/sms-api/upload}
    read -r -p "Cloud Login URL [default: https://portal.smsiotpk.com/sms-api/auth/login]: " LOGIN_URL
    LOGIN_URL=${LOGIN_URL:-https://portal.smsiotpk.com/sms-api/auth/login}
    read -r -p "Cloud Events Base URL [default: http://100.84.164.127:8181/api/events]: " CLOUD_BASE
    CLOUD_BASE=${CLOUD_BASE:-http://100.84.164.127:8181/api/events}
    read -r -p "Cloud Username [default: sms]: " CLOUD_USER
    CLOUD_USER=${CLOUD_USER:-sms}
    read -r -p "Cloud Password: " CLOUD_PASS
fi
read -r -p "Frigate MQTT prefix [default: frigate-165]: " MQTT_PREFIX
MQTT_PREFIX=${MQTT_PREFIX:-frigate-165}

# ── DEPENDENCIES ─────────────────────────────────────────────────
info "Installing dependencies..."
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq curl git openssl python3 ca-certificates gnupg

if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker ${SUDO_USER:-$USER}
    success "Docker installed"
fi

# ── CLONE REPO ───────────────────────────────────────────────────
INSTALL_DIR="${HOME}/sms-iot"
info "Setting up in $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing installation..."
    git -C $INSTALL_DIR pull
else
    git clone https://github.com/adnankhanodoo/sms-iot-deploy.git $INSTALL_DIR
fi
cd $INSTALL_DIR

# ── SSL CERTS ────────────────────────────────────────────────────
info "Generating SSL certificate..."
mkdir -p ssl
openssl req -x509 -nodes -days 36500 -newkey rsa:2048 \
    -keyout ssl/frigate.key -out ssl/frigate.crt \
    -subj "/C=PK/ST=Islamabad/L=Islamabad/O=SMS/OU=IT/CN=$DEVICE_IP" 2>/dev/null
cat ssl/frigate.crt ssl/frigate.key > ssl/shared.pem
cp ssl/frigate.crt ssl/fullchain.pem
cp ssl/frigate.key ssl/privkey.pem
success "SSL certs generated (100 year)"

# ── DOCKER LOG LIMITS ────────────────────────────────────────────
info "Configuring Docker log limits..."
$SUDO bash -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF'
$SUDO systemctl restart docker
sleep 3

# ── UPDATE CONFIGS WITH IP ────────────────────────────────────────
info "Updating configs with your IP ($DEVICE_IP)..."
sed -i "s/192\.168\.51\.211/$DEVICE_IP/g" \
    mosquitto/mosquitto.conf \
    nginx/frigate-nginx.conf \
    frigate/config/config.yml 2>/dev/null || true

sed -i "s/OR_HOSTNAME=.*/OR_HOSTNAME=$OR_HOSTNAME/" docker-compose.yml 2>/dev/null || true

# ── UPDATE EVENT QUEUE SCRIPT ─────────────────────────────────────
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
    info "Configuring event-queue for cloud upload..."
    sed -i "s|UPLOAD_URL = .*|UPLOAD_URL = \"$UPLOAD_URL\"|" event-queue/event_queue.py
    sed -i "s|LOGIN_URL = .*|LOGIN_URL = \"$LOGIN_URL\"|" event-queue/event_queue.py
    sed -i "s|CLOUD_BASE = .*|CLOUD_BASE = \"$CLOUD_BASE\"|" event-queue/event_queue.py
    sed -i "s|CLOUD_USER = .*|CLOUD_USER = \"$CLOUD_USER\"|" event-queue/event_queue.py
    sed -i "s|CLOUD_PASS = .*|CLOUD_PASS = \"$CLOUD_PASS\"|" event-queue/event_queue.py
    sed -i "s|SOURCE_TOPIC = .*|SOURCE_TOPIC = \"$MQTT_PREFIX/events\"|" event-queue/event_queue.py
    success "Cloud upload configured"
fi

# ── GENERATE DOCKER COMPOSE ──────────────────────────────────────
info "Generating docker-compose.yml..."
python3 $INSTALL_DIR/scripts/generate_compose.py \
    "$DEVICE_IP" "$OR_HOSTNAME" "$DEPLOY_FRIGATE" "$DEPLOY_ZIGBEE" 2>/dev/null || true

# Add event-queue to compose if cloud enabled
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
    if ! grep -q "event-queue" docker-compose.yml; then
        cat >> docker-compose.yml << EOF

  event-queue:
    build: ./event-queue
    container_name: sms-event-queue
    restart: always
    network_mode: host
    volumes:
      - ./event-queue/event_queue.py:/app/event_queue.py
EOF
    fi
fi

# ── START SERVICES ───────────────────────────────────────────────
info "Pulling Docker images (this may take a few minutes)..."
docker compose pull
info "Starting all services..."
docker compose up -d
success "All services started"

# ── RESTORE OPENREMOTE DATABASE ──────────────────────────────────
if [ -f "$INSTALL_DIR/openremote/openremote_db.sql.gz" ]; then
    info "Waiting for PostgreSQL to be ready (15s)..."
    sleep 15
    info "Restoring OpenRemote database..."
    docker exec smarthome-postgresql psql -U postgres -c "DROP DATABASE IF EXISTS openremote;" 2>/dev/null
    docker exec smarthome-postgresql psql -U postgres -c "CREATE DATABASE openremote;" 2>/dev/null
    gunzip -c $INSTALL_DIR/openremote/openremote_db.sql.gz | \
        docker exec -i smarthome-postgresql psql -U postgres openremote 2>/dev/null
    docker restart smarthome-manager
    success "Database restored"

    info "Updating MQTT agent hostname..."
    sleep 15
    docker exec smarthome-postgresql psql -U postgres openremote -c \
        "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') \
         WHERE type = 'MQTTAgent';" 2>/dev/null || true

    # Update MQTT prefix in OpenRemote
    if [ "$MQTT_PREFIX" != "frigate-165" ]; then
        info "Updating MQTT topics with prefix: $MQTT_PREFIX..."
        docker exec smarthome-postgresql psql -U postgres openremote -c \
            "UPDATE asset SET attributes = replace(attributes::text, 'frigate-165', '$MQTT_PREFIX')::jsonb \
             WHERE attributes::text LIKE '%frigate-165%';" 2>/dev/null || true
    fi
    success "OpenRemote configured"
fi

# ── WAIT FOR OPENREMOTE ──────────────────────────────────────────
info "Waiting for OpenRemote to be ready (90s)..."
for i in $(seq 1 18); do
    if curl -sk https://$DEVICE_IP/api/master/info &>/dev/null; then
        success "OpenRemote ready"; break
    fi
    echo -n "."; sleep 5
done
echo ""

# ── IMPORT ASSETS ────────────────────────────────────────────────
if [ -f "$INSTALL_DIR/openremote/assets_backup.json" ]; then
    info "Importing OpenRemote assets..."
    python3 $INSTALL_DIR/openremote/import_assets.py "$DEVICE_IP" && \
        success "Assets imported" || warn "Asset import failed"
fi

# ── BUILD EVENT QUEUE ────────────────────────────────────────────
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
    info "Building event-queue container..."
    docker compose build event-queue && \
        docker compose up -d event-queue && \
        success "Event queue running" || warn "Event queue build failed"
fi

# ── DONE ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       SMS Sentinel AI — Ready! ✅        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dashboard:   ${BLUE}https://$DEVICE_IP${NC}  (admin / secret)"
echo -e "  Frigate:     ${BLUE}https://$DEVICE_IP:8443${NC}"
echo -e "  go2rtc:      ${BLUE}http://$DEVICE_IP:1984${NC}"
echo -e "  MQTT:        ${BLUE}$DEVICE_IP:1883${NC}  (prefix: $MQTT_PREFIX)"
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
echo -e "  Cloud:       ${BLUE}$CLOUD_BASE${NC}"
echo -e "  Event Queue: ${BLUE}docker logs sms-event-queue${NC}"
fi
echo ""
echo -e "  ${YELLOW}Note: Accept SSL certificate warning in browser${NC}"
echo ""
