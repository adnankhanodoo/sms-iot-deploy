#!/bin/bash
# ================================================================
# SMS IoT Platform — Smart Installer v2.1
# github.com/adnankhanodoo/sms-iot-deploy
# ================================================================

set -e

# ── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}  ▸${NC} $1"; }
success() { echo -e "${GREEN}  ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
error()   { echo -e "${RED}  ✗${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}══ $1 ══${NC}"; }

# ── Spinner function ──────────────────────────────────────────────
spinner() {
    local pid=$1
    local msg=$2
    local SPINCHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        echo -ne "\r${BLUE}  ▸${NC} $msg ${SPINCHARS:$i:1} "
        sleep 0.1
    done
    wait $pid
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo -e "\r${GREEN}  ✓${NC} $msg      "
    else
        echo -e "\r${RED}  ✗${NC} $msg failed"
        return $exit_code
    fi
}

# ── Banner ────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║         SMS IoT Platform Installer v2.1          ║"
echo "  ║         github.com/adnankhanodoo/sms-iot-deploy  ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect IP ─────────────────────────────────────────────────────
detect_ip() {
    IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    if [ -z "$IP" ]; then
        IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i !~ /^172\.|^127\./) {print $i; exit}}')
    fi
    if [ -z "$IP" ]; then
        IP=$(hostname -I | awk '{print $1}')
    fi
    echo "$IP"
}

DEVICE_IP=$(detect_ip)
INSTALL_DIR="${HOME}/sms-iot"
REPO_URL="https://github.com/adnankhanodoo/sms-iot-deploy.git"
[[ $EUID -ne 0 ]] && SUDO="sudo" || SUDO=""

# ── Menu ──────────────────────────────────────────────────────────
echo -e "  ${BOLD}Detected IP:${NC} ${GREEN}$DEVICE_IP${NC}"
echo -e "  ${BOLD}Install dir:${NC} $INSTALL_DIR"
echo ""
echo -e "  ${BOLD}What would you like to do?${NC}"
echo ""
echo -e "  ${CYAN}1)${NC} Install full stack (OpenRemote + Frigate + MQTT + Zigbee)"
echo -e "  ${CYAN}2)${NC} Install OpenRemote only (dashboard + MQTT broker)"
echo -e "  ${CYAN}3)${NC} Install/Update Frigate NVR only"
echo -e "  ${CYAN}4)${NC} Update existing installation (pull latest)"
echo -e "  ${CYAN}5)${NC} Fix network (update IPs after network change)"
echo ""
read -r -p "  Enter choice [1-5]: " CHOICE
echo ""

case $CHOICE in
    1) MODE="full" ;;
    2) MODE="openremote" ;;
    3) MODE="frigate" ;;
    4) MODE="update" ;;
    5) MODE="fix_network" ;;
    *) error "Invalid choice" ;;
esac

DEPLOY_ZIGBEE="n"
if [ "$MODE" = "full" ]; then
    read -r -p "  Deploy Zigbee2MQTT? (requires USB dongle) [y/n]: " DEPLOY_ZIGBEE
fi

echo ""
echo -e "  ${BOLD}Configuration:${NC}"
echo -e "    Mode:      ${GREEN}$MODE${NC}"
echo -e "    Device IP: ${GREEN}$DEVICE_IP${NC}"
[ "$MODE" = "full" ] && echo -e "    Zigbee:    ${GREEN}$DEPLOY_ZIGBEE${NC}"
echo ""
read -r -p "  Continue? [y/n]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "Cancelled." && exit 0

# ── Fix network mode ──────────────────────────────────────────────
if [ "$MODE" = "fix_network" ]; then
    step "Fixing Network Configuration"
    info "Detected IP: $DEVICE_IP"
    if docker ps | grep -q smarthome-postgresql; then
        docker exec smarthome-postgresql psql -U postgres openremote -c \
            "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') WHERE type = 'MQTTAgent';" &>/dev/null || true
        docker restart smarthome-manager &>/dev/null
        success "MQTT agents updated to use hostname"
    fi
    if docker ps | grep -q frigate; then
        CONFIG="$INSTALL_DIR/frigate/config/config.yml"
        [ -f "$CONFIG" ] && sed -i 's/^  host: .*/  host: mosquitto/' "$CONFIG"
        docker restart frigate &>/dev/null
        success "Frigate MQTT updated"
    fi
    success "Network configuration fixed!"
    exit 0
fi

# ── Step 1: System Dependencies ───────────────────────────────────
step "Step 1/7: Installing System Dependencies"
( $SUDO apt-get update -qq 2>/dev/null ) &
spinner $! "Updating package lists"

( $SUDO apt-get install -y -qq curl git openssl python3 ca-certificates gnupg lsb-release 2>/dev/null ) &
spinner $! "Installing required packages"
success "System packages ready"

# ── Step 2: Docker ────────────────────────────────────────────────
step "Step 2/7: Setting Up Docker"
if command -v docker &>/dev/null; then
    success "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    info "Downloading and installing Docker (this takes 2-3 minutes)..."
    ( curl -fsSL https://get.docker.com | $SUDO sh ) &>/dev/null &
    spinner $! "Installing Docker engine"
    $SUDO usermod -aG docker ${SUDO_USER:-$USER} 2>/dev/null || true
    success "Docker installed"

    ( $SUDO bash -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF
systemctl restart docker' ) &>/dev/null &
    spinner $! "Configuring Docker log limits"
    sleep 3
fi

# ── Step 3: Clone/Update repo ─────────────────────────────────────
step "Step 3/7: Setting Up Installation Files"
if [ -d "$INSTALL_DIR/.git" ]; then
    ( git -C $INSTALL_DIR fetch origin &>/dev/null && git -C $INSTALL_DIR reset --hard origin/main &>/dev/null ) &
    spinner $! "Updating installation files from GitHub"
    success "Files updated"
else
    ( git clone $REPO_URL $INSTALL_DIR &>/dev/null ) &
    spinner $! "Downloading files from GitHub"
    success "Files downloaded to $INSTALL_DIR"
fi
cd $INSTALL_DIR

# ── Step 4: SSL cert ──────────────────────────────────────────────
step "Step 4/7: Generating SSL Certificate"
mkdir -p ssl
if [ ! -f ssl/frigate.crt ]; then
    ( openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout ssl/frigate.key -out ssl/frigate.crt \
        -subj "/CN=$DEVICE_IP" 2>/dev/null ) &
    spinner $! "Generating self-signed SSL certificate (10 years)"
else
    success "SSL certificate already exists"
fi

# ── Step 5: docker-compose ────────────────────────────────────────
step "Step 5/7: Configuring Services"

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
PYEOF
success "docker-compose.yml configured"

# ── Step 6: Pull & Start ──────────────────────────────────────────
step "Step 6/7: Downloading & Starting Services"

# Pull images one by one with progress
IMAGES=$(docker compose config --images 2>/dev/null | sort -u)
TOTAL=$(echo "$IMAGES" | wc -l)
COUNT=0
info "Downloading $TOTAL service images..."
echo ""
echo "$IMAGES" | while read -r img; do
    COUNT=$((COUNT + 1))
    echo -e "  ${BLUE}⬇${NC}  [$COUNT/$TOTAL] Downloading: ${CYAN}$img${NC}"
    docker pull "$img" 2>&1 | grep -E "Pulling from|Pull complete|Downloaded newer|Already exists" | while read -r l; do echo -e "    ${BLUE}▸${NC} $l"; done
    echo -e "  ${GREEN}✓${NC}  [$COUNT/$TOTAL] Ready: ${CYAN}$img${NC}\n"
done
echo ""
success "All images downloaded"

( docker compose up -d --remove-orphans 2>/dev/null ) &
spinner $! "Starting all services"
success "All services started"

# ── Step 7: Restore database ──────────────────────────────────────
step "Step 7/7: Restoring Data & Configuring"

if [ -f "$INSTALL_DIR/openremote/openremote_db.sql.gz" ]; then
    # Wait for PostgreSQL
    info "Waiting for PostgreSQL..."
    for i in $(seq 1 20); do
        docker exec smarthome-postgresql pg_isready -U postgres &>/dev/null && break
        sleep 3
        echo -ne "\r  ${BLUE}▸${NC} Waiting for PostgreSQL... ($((i*3))s)"
    done
    echo ""

    ( docker stop smarthome-manager smarthome-keycloak &>/dev/null; sleep 2 ) &
    spinner $! "Stopping services for clean restore"

    ( docker exec smarthome-postgresql psql -U postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='openremote';" &>/dev/null; \
      docker exec smarthome-postgresql psql -U postgres -c "DROP DATABASE IF EXISTS openremote;" &>/dev/null; \
      docker exec smarthome-postgresql psql -U postgres -c "CREATE DATABASE openremote;" &>/dev/null ) &
    spinner $! "Preparing fresh database"

    ( gunzip -c $INSTALL_DIR/openremote/openremote_db.sql.gz | \
        docker exec -i smarthome-postgresql psql -U postgres openremote &>/dev/null ) &
    spinner $! "Restoring assets, rules and settings"

    ( docker exec smarthome-postgresql psql -U postgres openremote -c \
        "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') WHERE type = 'MQTTAgent';" &>/dev/null ) &
    spinner $! "Configuring MQTT hostname"

    ( docker start smarthome-keycloak smarthome-manager &>/dev/null ) &
    spinner $! "Starting OpenRemote services"
    success "All data restored successfully"
else
    warn "No database backup found — starting fresh"
fi

# Wait for OpenRemote with progress
info "Waiting for OpenRemote to be ready..."
WAIT=0
while [ $WAIT -lt 120 ]; do
    if curl -sk https://localhost/api/master/info &>/dev/null; then
        break
    fi
    WAIT=$((WAIT + 3))
    PCT=$(( WAIT * 100 / 120 ))
    [ $PCT -gt 100 ] && PCT=99
    FILLED=$(( PCT / 5 ))
    BAR=""
    for i in $(seq 1 20); do
        [ $i -le $FILLED ] && BAR="${BAR}█" || BAR="${BAR}░"
    done
    echo -e "  ${BLUE}⬇${NC}  [$COUNT/$TOTAL] Downloading: ${CYAN}$img${NC}"
    docker pull "$img" 2>&1 | grep -E "Pulling from|Pull complete|Downloaded newer|Already exists" | while read -r l; do echo -e "    ${BLUE}▸${NC} $l"; done
    echo -e "  ${GREEN}✓${NC}  [$COUNT/$TOTAL] Ready: ${CYAN}$img${NC}\n"
