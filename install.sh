#!/bin/bash
# ================================================================
# SMS Sentinel AI — Installer v2.2
# One command: curl -fsSL https://raw.githubusercontent.com/adnankhanodoo/sms-iot-deploy/main/install.sh | sudo bash
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║    SMS Sentinel AI — Installer v2.2     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── AUTO SUDO ────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "Requesting sudo access..."
    exec sudo bash "$0" "$@"
fi

# ── AUTO DETECT IP ────────────────────────────────────────────────
AUTO_IP=$(hostname -I | awk '{print $1}')

# ── READ INPUT (works both piped and direct) ──────────────────────
if [ -t 0 ]; then
    # Interactive mode
    echo -e "  Detected IP: ${GREEN}$AUTO_IP${NC}"
    read -r -p "  Device LAN IP [$AUTO_IP]: " DEVICE_IP
    DEVICE_IP=${DEVICE_IP:-$AUTO_IP}
    read -r -p "  OpenRemote hostname [$DEVICE_IP]: " OR_HOSTNAME
    OR_HOSTNAME=${OR_HOSTNAME:-$DEVICE_IP}
    read -r -p "  Deploy Frigate NVR? (y/n) [y]: " DEPLOY_FRIGATE
    DEPLOY_FRIGATE=${DEPLOY_FRIGATE:-y}
    read -r -p "  Deploy Zigbee2MQTT? (y/n) [y]: " DEPLOY_ZIGBEE
    DEPLOY_ZIGBEE=${DEPLOY_ZIGBEE:-y}
    read -r -p "  Enable Cloud Upload? (y/n) [y]: " DEPLOY_CLOUD
    DEPLOY_CLOUD=${DEPLOY_CLOUD:-y}
    if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
        read -r -p "  Cloud Upload URL [https://portal.smsiotpk.com/sms-api/upload]: " UPLOAD_URL
        UPLOAD_URL=${UPLOAD_URL:-https://portal.smsiotpk.com/sms-api/upload}
        read -r -p "  Cloud Login URL [https://portal.smsiotpk.com/sms-api/auth/login]: " LOGIN_URL
        LOGIN_URL=${LOGIN_URL:-https://portal.smsiotpk.com/sms-api/auth/login}
        read -r -p "  Cloud Events Base URL [http://100.84.164.127:8181/api/events]: " CLOUD_BASE
        CLOUD_BASE=${CLOUD_BASE:-http://100.84.164.127:8181/api/events}
        read -r -p "  Cloud Username [sms]: " CLOUD_USER
        CLOUD_USER=${CLOUD_USER:-sms}
        read -r -p "  Cloud Password [SmsIoT@2026]: " CLOUD_PASS
        CLOUD_PASS=${CLOUD_PASS:-SmsIoT@2026}
    fi
    read -r -p "  Frigate MQTT prefix [frigate-165]: " MQTT_PREFIX
    MQTT_PREFIX=${MQTT_PREFIX:-frigate-165}
else
    # Piped mode — use all defaults
    DEVICE_IP=$AUTO_IP
    OR_HOSTNAME=$AUTO_IP
    DEPLOY_FRIGATE=y
    DEPLOY_ZIGBEE=y
    DEPLOY_CLOUD=y
    UPLOAD_URL="https://portal.smsiotpk.com/sms-api/upload"
    LOGIN_URL="https://portal.smsiotpk.com/sms-api/auth/login"
    CLOUD_BASE="http://100.84.164.127:8181/api/events"
    CLOUD_USER="sms"
    CLOUD_PASS="SmsIoT@2026"
    MQTT_PREFIX="frigate-165"
    echo -e "  ${YELLOW}Running in auto mode with defaults${NC}"
    echo -e "  Device IP: ${GREEN}$DEVICE_IP${NC}"
fi

echo ""
info "Starting SMS Sentinel AI installation..."

# ── DEPENDENCIES ─────────────────────────────────────────────────
info "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq curl git openssl python3 ca-certificates gnupg

if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ${SUDO_USER:-$USER} 2>/dev/null || true
    success "Docker installed"
fi

# Fix Docker socket permissions
chmod 666 /var/run/docker.sock 2>/dev/null || true

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
info "Generating SSL certificates (100 years)..."
mkdir -p ssl
openssl req -x509 -nodes -days 36500 -newkey rsa:2048 \
    -keyout ssl/frigate.key -out ssl/frigate.crt \
    -subj "/C=PK/ST=Islamabad/L=Islamabad/O=SMS/OU=IT/CN=$DEVICE_IP" 2>/dev/null
cat ssl/frigate.crt ssl/frigate.key > ssl/shared.pem
cp ssl/frigate.key ssl/shared.key
cp ssl/frigate.crt ssl/shared.crt
cp ssl/frigate.crt ssl/fullchain.pem
cp ssl/frigate.key ssl/privkey.pem
chattr -i ssl/fullchain.pem ssl/privkey.pem 2>/dev/null || true
chattr +i ssl/fullchain.pem ssl/privkey.pem 2>/dev/null || true
success "SSL certs generated"

# ── DOCKER LOG LIMITS ────────────────────────────────────────────
info "Configuring Docker log limits..."
bash -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF'
systemctl restart docker
sleep 3
chmod 666 /var/run/docker.sock 2>/dev/null || true

# ── UPDATE CONFIGS ────────────────────────────────────────────────
info "Updating configs with IP: $DEVICE_IP..."
sed -i "s/192\.168\.51\.211/$DEVICE_IP/g" \
    mosquitto/mosquitto.conf \
    nginx/frigate-nginx.conf \
    frigate/config/config.yml 2>/dev/null || true

# ── UPDATE EVENT QUEUE ────────────────────────────────────────────
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
    info "Configuring cloud upload..."
    sed -i "s|UPLOAD_URL = .*|UPLOAD_URL = \"$UPLOAD_URL\"|" event-queue/event_queue.py 2>/dev/null || true
    sed -i "s|LOGIN_URL = .*|LOGIN_URL = \"$LOGIN_URL\"|" event-queue/event_queue.py 2>/dev/null || true
    sed -i "s|CLOUD_BASE = .*|CLOUD_BASE = \"$CLOUD_BASE\"|" event-queue/event_queue.py 2>/dev/null || true
    sed -i "s|CLOUD_USER = .*|CLOUD_USER = \"$CLOUD_USER\"|" event-queue/event_queue.py 2>/dev/null || true
    sed -i "s|CLOUD_PASS = .*|CLOUD_PASS = \"$CLOUD_PASS\"|" event-queue/event_queue.py 2>/dev/null || true
    sed -i "s|SOURCE_TOPIC = .*|SOURCE_TOPIC = \"$MQTT_PREFIX/events\"|" event-queue/event_queue.py 2>/dev/null || true
    success "Cloud upload configured"
fi

# ── GENERATE DOCKER COMPOSE ──────────────────────────────────────
info "Generating docker-compose.yml..."
python3 $INSTALL_DIR/scripts/generate_compose.py \
    "$DEVICE_IP" "$OR_HOSTNAME" "$DEPLOY_FRIGATE" "$DEPLOY_ZIGBEE" 2>/dev/null || true

# Add event-queue service if not present
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
    if ! grep -q "sms-event-queue" docker-compose.yml 2>/dev/null; then
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
info "Pulling Docker images (may take a few minutes)..."
docker compose pull
info "Starting all services..."
# Remove immutable flag before SSL cert copy
chattr -i ssl/fullchain.pem ssl/privkey.pem 2>/dev/null || true
docker compose up -d
success "All services started"

# ── RESTORE OPENREMOTE DATABASE ──────────────────────────────────
if [ -f "$INSTALL_DIR/openremote/openremote_db.sql.gz" ]; then
    # Ensure proxy starts after manager is ready
info "Starting proxy..."
docker start smarthome-proxy 2>/dev/null || docker compose up -d proxy
sleep 5

info "Waiting for PostgreSQL (15s)..."
    sleep 15
    info "Restoring OpenRemote database..."
    docker exec smarthome-postgresql psql -U postgres -c "DROP DATABASE IF EXISTS openremote;" 2>/dev/null
    docker exec smarthome-postgresql psql -U postgres -c "CREATE DATABASE openremote;" 2>/dev/null
    gunzip -c $INSTALL_DIR/openremote/openremote_db.sql.gz | \
        docker exec -i smarthome-postgresql psql -U postgres openremote 2>/dev/null
    sleep 5; MANAGER=$(docker ps -a --format "{{.Names}}" | grep -i manager | head -1); echo "Manager container: $MANAGER"; [ -n "$MANAGER" ] && docker restart $MANAGER || true
    success "Database restored"

    info "Updating MQTT agent hostname..."
    sleep 15
    docker exec smarthome-postgresql psql -U postgres openremote -c \
        "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') \
         WHERE type = 'MQTTAgent';" 2>/dev/null || true

    if [ "$MQTT_PREFIX" != "frigate-165" ]; then
        info "Updating MQTT topics prefix to: $MQTT_PREFIX..."
        docker exec smarthome-postgresql psql -U postgres openremote -c \
            "UPDATE asset SET attributes = replace(attributes::text, 'frigate-165', '$MQTT_PREFIX')::jsonb \
             WHERE attributes::text LIKE '%frigate-165%';" 2>/dev/null || true
    fi
    success "OpenRemote configured"
fi

# ── WAIT FOR OPENREMOTE ──────────────────────────────────────────
info "Waiting for OpenRemote (90s)..."
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
    cd $INSTALL_DIR
    docker compose build event-queue 2>/dev/null && \
    docker compose up -d event-queue && \
        success "Event queue running" || warn "Event queue build failed — check internet and retry: cd ~/sms-iot && docker compose build event-queue"
fi

# ── DONE ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      SMS Sentinel AI — Ready! ✅         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dashboard:   ${BLUE}https://$DEVICE_IP${NC}  (admin / secret)"
echo -e "  Frigate:     ${BLUE}https://$DEVICE_IP:8443${NC}"
echo -e "  go2rtc:      ${BLUE}http://$DEVICE_IP:1984${NC}"
echo -e "  MQTT:        ${BLUE}$DEVICE_IP:1883${NC}  prefix: $MQTT_PREFIX"
if [[ "$DEPLOY_CLOUD" =~ ^[Yy]$ ]]; then
echo -e "  Cloud:       ${BLUE}$CLOUD_BASE${NC}"
echo -e "  Event Queue: ${BLUE}docker logs -f sms-event-queue${NC}"
fi
echo ""
echo -e "  ${YELLOW}Tip: Accept SSL warning in browser${NC}"
echo -e "  ${YELLOW}Tip: docker compose -f ~/sms-iot/docker-compose.yml logs -f${NC}"
echo ""
