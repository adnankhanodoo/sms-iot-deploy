#!/bin/bash
# ================================================================
# SMS IoT Platform — Smart Installer v3.0
# github.com/adnankhanodoo/sms-iot-deploy
cd $HOME
# Re-run with sudo if docker not accessible
if ! docker info >/dev/null 2>&1 && [ $EUID -ne 0 ]; then
    echo -e "  Restarting with sudo for Docker access..."
    exec sudo -E bash "$0" "$@"
fi
# ================================================================

# ── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}  ▸${NC} $1"; }
success() { echo -e "${GREEN}  ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
error()   { echo -e "${RED}  ✗ ERROR:${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}══ $1 ══${NC}"; }

# ── Banner ────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║         SMS IoT Platform Installer v3.0          ║"
echo "  ║         github.com/adnankhanodoo/sms-iot-deploy  ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Auto-detect IP ────────────────────────────────────────────────
DEVICE_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
[ -z "$DEVICE_IP" ] && DEVICE_IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i !~ /^172\.|^127\./) {print $i; exit}}')
[ -z "$DEVICE_IP" ] && DEVICE_IP=$(hostname -I | awk '{print $1}')

INSTALL_DIR="${HOME}/sms-iot"
REPO_URL="https://github.com/adnankhanodoo/sms-iot-deploy.git"
[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

echo -e "  ${BOLD}Detected IP:${NC} ${GREEN}$DEVICE_IP${NC}"
echo -e "  ${BOLD}Install dir:${NC} $INSTALL_DIR"
echo ""

# ── Menu ──────────────────────────────────────────────────────────
echo -e "  ${BOLD}What would you like to do?${NC}"
echo ""
echo -e "  ${CYAN}1)${NC} Install full stack  (OpenRemote + Frigate + MQTT + Zigbee)"
echo -e "  ${CYAN}2)${NC} Install OpenRemote only  (dashboard + MQTT broker)"
echo -e "  ${CYAN}3)${NC} Install Frigate NVR only"
echo -e "  ${CYAN}4)${NC} Update existing installation"
echo -e "  ${CYAN}5)${NC} Fix network  (after IP change)"
echo ""
read -r -p "  Enter choice [1-5]: " CHOICE
echo ""

case $CHOICE in
    1) MODE="full" ;;
    2) MODE="openremote" ;;
    3) MODE="frigate" ;;
    4) MODE="update" ;;
    5) MODE="fix_network" ;;
    *) error "Invalid choice. Run script again and enter 1-5." ;;
esac

DEPLOY_ZIGBEE="n"
if [ "$MODE" = "full" ]; then
    read -r -p "  Deploy Zigbee2MQTT? (requires USB Zigbee dongle) [y/n]: " DEPLOY_ZIGBEE
fi

echo ""
echo -e "  ${BOLD}Summary:${NC}"
echo -e "    Mode:      ${GREEN}$MODE${NC}"
echo -e "    Device IP: ${GREEN}$DEVICE_IP${NC}"
[ "$MODE" = "full" ] && echo -e "    Zigbee:    ${GREEN}$DEPLOY_ZIGBEE${NC}"
echo ""
read -r -p "  Proceed with installation? [y/n]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "  Cancelled." && exit 0
echo ""

# ────────────────────────────────────────────────────────────────
# FIX NETWORK MODE
# ────────────────────────────────────────────────────────────────
if [ "$MODE" = "fix_network" ]; then
    step "Fixing Network Configuration"
    info "Device IP: $DEVICE_IP"

    if sudo docker ps --format '{{.Names}}' | grep -q smarthome-postgresql; then
        info "Updating MQTT agents to use hostname 'mosquitto'..."
        sudo docker exec smarthome-postgresql psql -U postgres openremote -c \
            "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') WHERE type = 'MQTTAgent';" 2>/dev/null && \
            success "MQTT agents updated" || warn "Could not update MQTT agents"
        sudo docker restart smarthome-manager >/dev/null 2>&1
        success "OpenRemote restarted"
    else
        warn "OpenRemote not running"
    fi

    if sudo docker ps --format '{{.Names}}' | grep -q "^frigate$"; then
        CONFIG="$INSTALL_DIR/frigate/config/config.yml"
        [ -f "$CONFIG" ] && sed -i 's/^  host: .*/  host: mosquitto/' "$CONFIG" && \
            docker restart frigate >/dev/null 2>&1 && success "Frigate MQTT updated"
    fi

    echo ""
    success "Network configuration fixed!"
    echo -e "\n  ${GREEN}OpenRemote:${NC} https://$DEVICE_IP  (admin/secret)"
    echo ""
    exit 0
fi

# ────────────────────────────────────────────────────────────────
# STEP 1: System dependencies
# ────────────────────────────────────────────────────────────────
step "Step 1/6: Installing System Dependencies"
info "Updating package lists..."
$SUDO apt-get update -qq 2>/dev/null && success "Package lists updated"

info "Installing required packages..."
$SUDO apt-get install -y -qq curl git openssl python3 ca-certificates gnupg lsb-release 2>/dev/null && \
    success "Required packages installed"

# ────────────────────────────────────────────────────────────────
# STEP 2: Docker
# ────────────────────────────────────────────────────────────────
step "Step 2/6: Setting Up Docker"

if command -v docker &>/dev/null; then
    success "Docker already installed — $(docker --version | cut -d' ' -f3 | tr -d ',')"
else
    info "Installing Docker (this takes 2-3 minutes)..."
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker ${SUDO_USER:-$USER} 2>/dev/null || true
    # Allow docker without logout
    $SUDO chmod 666 /var/run/docker.sock 2>/dev/null || true
    success "Docker installed"

    info "Configuring Docker log limits..."
    $SUDO bash -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF'
    $SUDO systemctl restart docker
    sleep 5
    success "Docker configured"
fi

# ────────────────────────────────────────────────────────────────
# STEP 3: Clone/Update repo
# ────────────────────────────────────────────────────────────────
step "Step 3/6: Setting Up Installation Files"

if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating files from GitHub..."
    git -C $INSTALL_DIR fetch origin 2>/dev/null
    git -C $INSTALL_DIR reset --hard origin/main 2>/dev/null
    success "Files updated from GitHub"
else
    info "Downloading files from GitHub..."
    git clone $REPO_URL $INSTALL_DIR
    success "Files downloaded to $INSTALL_DIR"
fi

cd $INSTALL_DIR

# SSL cert
mkdir -p ssl
if [ ! -f ssl/frigate.crt ]; then
    info "Generating SSL certificate..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout ssl/frigate.key -out ssl/frigate.crt \
        -subj "/CN=$DEVICE_IP" 2>/dev/null
    success "SSL certificate generated (valid 10 years)"
else
    success "SSL certificate already exists"
fi

# ────────────────────────────────────────────────────────────────
# STEP 4: Generate docker-compose
# ────────────────────────────────────────────────────────────────
step "Step 4/6: Configuring Services"
info "Generating docker-compose.yml..."

python3 << PYEOF
mode = "$MODE"
zigbee = "$DEPLOY_ZIGBEE".lower() in ('y','yes')
deploy_frigate = mode in ('full', 'frigate', 'update')

compose = """services:

  proxy:
    image: openremote/proxy:latest
    container_name: smarthome-proxy
    restart: always
    depends_on: [manager]
    ports: ["80:80","443:443","8883:8883"]
    environment:
      - OR_HOSTNAME=192.168.50.199
      - OR_SSL_PORT=443
    volumes: [proxy-data:/deployment]

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
      - KEYCLOAK_ISSUER_BASE_URI=https://192.168.50.199/auth
      - KC_HOSTNAME=
      - KC_HOSTNAME_STRICT=false
    volumes: [keycloak-data:/opt/keycloak/data/h2]

  manager:
    image: openremote/manager:latest
    container_name: smarthome-manager
    restart: always
    depends_on: [keycloak,postgresql]
    environment:
      - OR_HOSTNAME=192.168.50.199
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

if zigbee:
    compose += """
  zigbee2mqtt:
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

if deploy_frigate:
    compose += """
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    restart: unless-stopped
    privileged: true
    shm_size: "512mb"
    ports:
      - "5000:5000"
      - "8971:8971"
      - "1935:1935"
      - "8554:8554"
      - "1984:1984"
      - "8555:8555"
      - "8555:8555/udp"
    volumes:
      - ./frigate/config:/config
      - /media/frigate:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    devices:
      - /dev/bus/usb:/dev/bus/usb
      - /dev/dri:/dev/dri
"""

compose += """
volumes:
  proxy-data:
  manager-data:
  postgresql-data:
  keycloak-data:
  mosquitto-data:
"""
with open("docker-compose.yml","w") as f:
    f.write(compose)
print("  docker-compose.yml generated")
PYEOF
success "Services configured"

# ────────────────────────────────────────────────────────────────
# STEP 5: Pull images & start
# ────────────────────────────────────────────────────────────────
step "Step 5/6: Downloading & Starting Services"

# Pull each image showing Docker's native output
IMAGES=$(sudo docker compose config --images 2>/dev/null | sort -u)
TOTAL=$(echo "$IMAGES" | grep -c .)
COUNT=0
info "Downloading $TOTAL service images..."
echo ""

echo "$IMAGES" | while read -r img; do
    [ -z "$img" ] && continue
    COUNT=$((COUNT + 1))
    echo -e "${CYAN}  ── [$COUNT/$TOTAL] $img ──────────────────────────────${NC}"
    sudo docker pull "$img"
    echo ""
done

success "All images downloaded"
echo ""

info "Starting all services..."
sudo docker compose up -d 2>&1 | grep -v "^$" | while read -r line; do
    echo "    $line"
done
success "All services started"

# ────────────────────────────────────────────────────────────────
# STEP 6: Restore database
# ────────────────────────────────────────────────────────────────
step "Step 6/6: Restoring Data & Final Configuration"

if [ -f "$INSTALL_DIR/openremote/openremote_db.sql.gz" ]; then

    info "Waiting for PostgreSQL to be ready..."
    for i in $(seq 1 30); do
        if sudo docker exec smarthome-postgresql pg_isready -U postgres >/dev/null 2>&1; then
            success "PostgreSQL is ready"
            break
        fi
        echo -ne "\r    Waiting... ${i}s"
        sleep 2
    done
    echo ""

    info "Stopping manager for clean restore..."
    sudo docker stop smarthome-manager smarthome-keycloak >/dev/null 2>&1 || true
    sleep 3

    info "Dropping old database..."
    sudo docker exec smarthome-postgresql psql -U postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='openremote';" >/dev/null 2>&1 || true
    sudo docker exec smarthome-postgresql psql -U postgres -c \
        "DROP DATABASE IF EXISTS openremote;" >/dev/null 2>&1
    sudo docker exec smarthome-postgresql psql -U postgres -c \
        "CREATE DATABASE openremote;" >/dev/null 2>&1
    success "Fresh database created"

    info "Restoring assets, rules and settings..."
    gunzip -c $INSTALL_DIR/openremote/openremote_db.sql.gz | \
        docker exec -i smarthome-postgresql psql -U postgres openremote >/dev/null 2>&1
    success "Database restored"

    info "Starting manager..."
    sudo docker start smarthome-keycloak >/dev/null 2>&1
    sleep 5
    docker start smarthome-manager >/dev/null 2>&1

    info "Waiting for asset table to be ready..."
    for i in $(seq 1 30); do
        COUNT=$(sudo docker exec smarthome-postgresql psql -U postgres openremote -t -c \
            "SELECT count(*) FROM asset;" 2>/dev/null | tr -d ' ')
        if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ] 2>/dev/null; then
            success "Database ready — $COUNT assets found"
            break
        fi
        echo -ne "\r    Initializing... ${i}s"
        sleep 3
    done
    echo ""

    info "Setting MQTT agents to use hostname..."
    sudo docker exec smarthome-postgresql psql -U postgres openremote -c \
        "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') WHERE type = 'MQTTAgent';" >/dev/null 2>&1 && \
        success "MQTT agents configured" || warn "MQTT agent update skipped"

    info "Restarting manager to apply changes..."
    sudo docker restart smarthome-manager >/dev/null 2>&1
    success "Manager restarted"

else
    warn "No database backup found — starting with fresh OpenRemote"
fi

# ── Wait for OpenRemote to be fully ready ─────────────────────────
info "Waiting for OpenRemote to be ready..."
for i in $(seq 1 40); do
    if curl -sk https://localhost/api/master/info >/dev/null 2>&1; then
        success "OpenRemote is ready!"
        break
    fi
    echo -ne "\r    Starting up... ${i}s / ~60s"
    sleep 3
done
echo ""

# Make sure proxy is running
sudo docker start smarthome-proxy >/dev/null 2>&1 || true

# ── Final Summary ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║           Installation Complete! 🎉              ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Service URLs:${NC}"
echo ""
echo -e "  ${CYAN}OpenRemote Dashboard${NC}"
echo -e "    🌐  https://$DEVICE_IP"
echo -e "    🔑  Login: admin / secret"
echo ""

if sudo docker ps --format '{{.Names}}' | grep -q "^frigate$"; then
echo -e "  ${CYAN}Frigate NVR${NC}"
echo -e "    📷  http://$DEVICE_IP:5000"
echo -e "    🔒  https://$DEVICE_IP:8443  (WebRTC/mic)"
echo -e "    📡  http://$DEVICE_IP:1984   (go2rtc)"
echo ""
fi

echo -e "  ${CYAN}MQTT Broker${NC}"
echo -e "    📨  $DEVICE_IP:1883  (hostname: mosquitto)"
echo ""

if sudo docker ps --format '{{.Names}}' | grep -q zigbee2mqtt; then
echo -e "  ${CYAN}Zigbee2MQTT${NC}"
echo -e "    🔌  http://$DEVICE_IP:8082"
echo ""
fi

echo -e "  ${BOLD}Tip:${NC} Browser will show SSL warning — click ${YELLOW}Advanced${NC} → ${YELLOW}Proceed${NC}"
echo ""
echo -e "  ${BOLD}Run again anytime:${NC}"
echo -e "    bash <(curl -fsSL https://raw.githubusercontent.com/adnankhanodoo/sms-iot-deploy/main/deploy.sh)"
echo ""

! groups | grep -q docker 2>/dev/null && \
    warn "Log out and back in to use Docker without sudo"

echo ""
