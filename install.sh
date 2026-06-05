#!/bin/bash
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║     SMS IoT Platform Installer v1.0     ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

read -r -p "Enter this device LAN IP (e.g. 192.168.51.199): " DEVICE_IP
read -r -p "OpenRemote hostname [default: $DEVICE_IP]: " OR_HOSTNAME
OR_HOSTNAME=${OR_HOSTNAME:-$DEVICE_IP}
read -r -p "Deploy Frigate NVR? (y/n): " DEPLOY_FRIGATE
read -r -p "Deploy Zigbee2MQTT? (y/n): " DEPLOY_ZIGBEE

info "Installing dependencies..."
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq curl git openssl python3 ca-certificates gnupg

if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker ${SUDO_USER:-$USER}
    success "Docker installed"
fi

INSTALL_DIR="${HOME}/sms-iot"
info "Setting up in $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing installation..."
    git -C $INSTALL_DIR pull
else
    git clone https://github.com/adnankhanodoo/sms-iot-deploy.git $INSTALL_DIR
fi
cd $INSTALL_DIR

info "Generating SSL certificate..."
mkdir -p ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout ssl/frigate.key -out ssl/frigate.crt \
    -subj "/CN=$DEVICE_IP" 2>/dev/null
success "SSL cert generated"

info "Configuring Docker log limits..."
$SUDO bash -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF'
$SUDO systemctl restart docker
sleep 3

info "Updating configs with your IP..."
sed -i "s/192.168.51.199/$DEVICE_IP/g" mosquitto/mosquitto.conf nginx/frigate-nginx.conf frigate/config/config.yml 2>/dev/null || true

info "Generating docker-compose.yml..."
python3 $INSTALL_DIR/scripts/generate_compose.py "$DEVICE_IP" "$OR_HOSTNAME" "$DEPLOY_FRIGATE" "$DEPLOY_ZIGBEE"
success "docker-compose.yml generated"

info "Starting services..."
docker compose pull
docker compose up -d
success "Services started"


# Restore OpenRemote database
if [ -f "$INSTALL_DIR/openremote/openremote_db.sql.gz" ]; then
    info "Waiting for PostgreSQL to be ready..."
    sleep 15
    info "Restoring OpenRemote database..."
    gunzip -c $INSTALL_DIR/openremote/openremote_db.sql.gz | docker exec -i smarthome-postgresql psql -U postgres openremote 2>/dev/null
    docker restart smarthome-manager
    success "Database restored"
fi
info "Waiting for OpenRemote (90s)..."
for i in $(seq 1 18); do
    if curl -sk https://$DEVICE_IP/api/master/info &>/dev/null; then
        success "OpenRemote ready"; break
    fi
    echo -n "."; sleep 5
done
echo ""

if [ -f "$INSTALL_DIR/openremote/assets_backup.json" ]; then
    info "Importing OpenRemote assets..."
    python3 $INSTALL_DIR/openremote/import_assets.py "$DEVICE_IP" && success "Assets imported" || warn "Asset import failed"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Installation Complete!           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  OpenRemote:  ${BLUE}https://$DEVICE_IP${NC}  (admin/secret)"
echo -e "  Frigate:     ${BLUE}http://$DEVICE_IP:5000${NC}"
echo -e "  go2rtc:      ${BLUE}http://$DEVICE_IP:1984${NC}"
echo -e "  MQTT:        ${BLUE}$DEVICE_IP:1883${NC}"
echo ""
