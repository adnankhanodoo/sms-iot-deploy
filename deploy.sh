#!/bin/bash
# ================================================================
# SMS IoT Platform — Smart Installer v2.0
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
progress(){ echo -ne "${BLUE}  ▸${NC} $1..."; }
done_msg(){ echo -e " ${GREEN}done${NC}"; }

# ── Banner ────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║         SMS IoT Platform Installer v2.0          ║"
echo "  ║         github.com/adnankhanodoo/sms-iot-deploy  ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect IP automatically ───────────────────────────────────────
detect_ip() {
    # Try to get the primary LAN IP (not loopback, not docker)
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

# ── Validate choice ───────────────────────────────────────────────
case $CHOICE in
    1) MODE="full" ;;
    2) MODE="openremote" ;;
    3) MODE="frigate" ;;
    4) MODE="update" ;;
    5) MODE="fix_network" ;;
    *) error "Invalid choice" ;;
esac

# ── Ask Zigbee only for full install ─────────────────────────────
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
        progress "Updating MQTT agent IPs in OpenRemote"
        docker exec smarthome-postgresql psql -U postgres openremote -c \
            "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') WHERE type = 'MQTTAgent';" 2>/dev/null || true
        done_msg
        docker restart smarthome-manager &>/dev/null
        success "OpenRemote MQTT agents updated"
    fi

    if docker ps | grep -q frigate; then
        progress "Updating Frigate MQTT config"
        CONFIG="$INSTALL_DIR/frigate/config/config.yml"
        [ -f "$CONFIG" ] && python3 -c "
import re, sys
c = open('$CONFIG').read()
c = re.sub(r'host:.*', 'host: mosquitto', c, count=1)
open('$CONFIG', 'w').write(c)
"
        docker restart frigate &>/dev/null
        done_msg
        success "Frigate MQTT updated"
    fi

    echo ""
    success "Network configuration fixed!"
    exit 0
fi

# ── Step 1: Install system dependencies ──────────────────────────
step "Step 1/7: Installing System Dependencies"

progress "Updating package lists"
$SUDO apt-get update -qq 2>/dev/null
done_msg

progress "Installing required packages"
$SUDO apt-get install -y -qq curl git openssl python3 ca-certificates gnupg lsb-release 2>/dev/null
done_msg
success "System packages ready"

# ── Step 2: Install Docker ────────────────────────────────────────
step "Step 2/7: Setting Up Docker"

if command -v docker &>/dev/null; then
    success "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    progress "Downloading and installing Docker"
    curl -fsSL https://get.docker.com | $SUDO sh &>/dev/null
    done_msg
    $SUDO usermod -aG docker ${SUDO_USER:-$USER} 2>/dev/null || true
    success "Docker installed"

    progress "Configuring Docker log limits"
    $SUDO bash -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF'
    $SUDO systemctl restart docker &>/dev/null
    sleep 3
    done_msg
fi

# ── Step 3: Clone/Update repo ─────────────────────────────────────
step "Step 3/7: Setting Up Installation Files"

if [ -d "$INSTALL_DIR/.git" ]; then
    progress "Updating existing installation files"
    git -C $INSTALL_DIR fetch origin &>/dev/null
    git -C $INSTALL_DIR reset --hard origin/main &>/dev/null
    done_msg
    success "Files updated from GitHub"
else
    progress "Downloading installation files from GitHub"
    git clone $REPO_URL $INSTALL_DIR &>/dev/null
    done_msg
    success "Files downloaded to $INSTALL_DIR"
fi

cd $INSTALL_DIR

# ── Step 4: Generate SSL cert ─────────────────────────────────────
step "Step 4/7: Generating SSL Certificate"

mkdir -p ssl
if [ ! -f ssl/frigate.crt ]; then
    progress "Generating self-signed SSL certificate"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout ssl/frigate.key -out ssl/frigate.crt \
        -subj "/CN=$DEVICE_IP" 2>/dev/null
    done_msg
    success "SSL certificate generated (10 years)"
else
    success "SSL certificate already exists"
fi

# ── Step 5: Generate docker-compose ──────────────────────────────
step "Step 5/7: Configuring Services"

progress "Generating docker-compose.yml"
python3 << PYEOF
import sys
mode = "$MODE"
zigbee = "$DEPLOY_ZIGBEE".lower() in ('y','yes')
device_ip = "$DEVICE_IP"

deploy_or = mode in ('full', 'openremote', 'update')
deploy_frigate = mode in ('full', 'frigate', 'update')

# Read existing compose if updating
import os
existing = ""
if os.path.exists("docker-compose.yml"):
    existing = open("docker-compose.yml").read()

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
print("Generated")
PYEOF
done_msg
success "docker-compose.yml configured"

# ── Step 6: Pull images & start ───────────────────────────────────
step "Step 6/7: Downloading & Starting Services"
info "This may take 5-15 minutes on first install..."
echo ""

# Get list of images to pull
IMAGES=$(docker compose config --images 2>/dev/null | sort -u)
TOTAL=$(echo "$IMAGES" | wc -l)
COUNT=0
info "Pulling $TOTAL Docker images (first time takes 5-15 min)..."
echo ""
echo "$IMAGES" | while read -r img; do
    COUNT=$((COUNT + 1))
    echo -ne "    ${BLUE}⬇${NC}  [$COUNT/$TOTAL] Downloading: ${CYAN}$img${NC}..."
    docker pull "$img" &>/dev/null && echo -e " ${GREEN}done${NC}" || echo -e " ${YELLOW}cached${NC}"
done
echo ""
success "All images ready"

progress "Starting all services"
docker compose up -d --remove-orphans 2>/dev/null || true
done_msg
success "All services started"

# ── Step 7: Restore database ──────────────────────────────────────
step "Step 7/7: Configuring & Restoring Data"

if [ -f "$INSTALL_DIR/openremote/openremote_db.sql.gz" ]; then
    info "Waiting for PostgreSQL to be ready..."
    for i in $(seq 1 20); do
        if docker exec smarthome-postgresql pg_isready -U postgres &>/dev/null; then
            break
        fi
        sleep 3
    done

    progress "Stopping manager for clean restore"
    docker stop smarthome-manager smarthome-keycloak &>/dev/null
    sleep 3
    done_msg

    progress "Terminating existing DB connections"
    docker exec smarthome-postgresql psql -U postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='openremote';" &>/dev/null || true
    done_msg

    progress "Dropping old database"
    docker exec smarthome-postgresql psql -U postgres -c "DROP DATABASE IF EXISTS openremote;" &>/dev/null
    done_msg

    progress "Creating fresh database"
    docker exec smarthome-postgresql psql -U postgres -c "CREATE DATABASE openremote;" &>/dev/null
    done_msg

    progress "Restoring OpenRemote data (assets, rules, settings)"
    gunzip -c $INSTALL_DIR/openremote/openremote_db.sql.gz | \
        docker exec -i smarthome-postgresql psql -U postgres openremote &>/dev/null
    done_msg

    progress "Setting MQTT agents to use hostname"
    docker exec smarthome-postgresql psql -U postgres openremote -c \
        "UPDATE asset SET attributes = jsonb_set(attributes, '{host,value}', '\"mosquitto\"') WHERE type = 'MQTTAgent';" &>/dev/null || true
    done_msg

    progress "Starting services"
    docker start smarthome-keycloak smarthome-manager &>/dev/null
    done_msg
    success "Database restored with all assets and settings"
else
    warn "No database backup found — starting with fresh OpenRemote"
fi

# ── Wait for OpenRemote ───────────────────────────────────────────
progress "Waiting for OpenRemote to be ready"
for i in $(seq 1 30); do
    if curl -sk https://localhost/api/master/info &>/dev/null; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
success "OpenRemote is ready"

# ── Final Summary ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║           Installation Complete! 🎉              ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Access your services:${NC}"
echo ""
echo -e "  ${CYAN}OpenRemote Dashboard${NC}"
echo -e "    ${GREEN}https://$DEVICE_IP${NC}  →  login: admin / secret"
echo ""

if docker ps | grep -q "frigate"; then
    echo -e "  ${CYAN}Frigate NVR${NC}"
    echo -e "    ${GREEN}http://$DEVICE_IP:5000${NC}  →  camera management"
    echo -e "    ${GREEN}https://$DEVICE_IP:8443${NC}  →  HTTPS (for mic/WebRTC)"
    echo -e "    ${GREEN}http://$DEVICE_IP:1984${NC}  →  go2rtc stream viewer"
    echo ""
fi

echo -e "  ${CYAN}MQTT Broker${NC}"
echo -e "    ${GREEN}$DEVICE_IP:1883${NC}  →  no auth required"
echo ""

if docker ps | grep -q "zigbee2mqtt"; then
    echo -e "  ${CYAN}Zigbee2MQTT${NC}"
    echo -e "    ${GREEN}http://$DEVICE_IP:8082${NC}  →  Zigbee device management"
    echo ""
fi

echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    Check services:  ${CYAN}docker ps${NC}"
echo -e "    Update platform: ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/adnankhanodoo/sms-iot-deploy/main/install.sh)${NC}"
echo -e "    Fix network:     ${CYAN}bash ~/sms-iot/scripts/update_ip.sh${NC}"
echo ""

if [ "$EUID" -ne 0 ] && ! groups | grep -q docker; then
    warn "Log out and back in to use Docker without sudo"
fi
echo ""
