#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}   SMS IoT — Mumble PTT Setup${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Detect NetBird IP
NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
LOCAL_IP=$(hostname -I | awk '{print $1}')

if [ -n "$NETBIRD_IP" ]; then
    echo -e "${GREEN}✓ NetBird detected: $NETBIRD_IP${NC}"
    ACCESS_IP="$NETBIRD_IP"
else
    echo -e "${YELLOW}⚠ NetBird not detected${NC}"
    read -p "Enter NetBird IP (or press Enter to use local IP $LOCAL_IP): " NB_MANUAL
    ACCESS_IP="${NB_MANUAL:-$LOCAL_IP}"
fi

WS_PORT=8080
MUMBLE_PORT=64738
CERT_DIR="$HOME/.mumble-ptt-certs"

echo ""
echo -e "${YELLOW}Installing dependencies...${NC}"

sudo apt update -qq
sudo apt install -y mumble-server sqlite3 python3-pip
sudo systemctl enable mumble-server

# Install nodejs if not present
if ! command -v npm &>/dev/null; then
    echo "Installing nodejs..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
    sudo apt install -y nodejs
fi

# Install websockify
echo "Installing websockify..."
pip3 install websockify --break-system-packages -q 2>/dev/null || \
pip install websockify --break-system-packages -q 2>/dev/null || true

# Patch websockify SSL for Python 3.12/3.14
PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
WS_PY="$HOME/.local/lib/python${PYVER}/site-packages/websockify/websockifyserver.py"
if [ -f "$WS_PY" ]; then
    grep -q "check_hostname = False" "$WS_PY" 2>/dev/null || \
    sed -i 's/context = ssl.create_default_context()/context = ssl.create_default_context()\n                    context.check_hostname = False\n                    context.verify_mode = ssl.CERT_NONE/' \
        "$WS_PY" 2>/dev/null || true
    echo -e "${GREEN}✓ websockify SSL patched${NC}"
fi

# Install mumble-web
if [ ! -d "$HOME/node_modules/mumble-web" ]; then
    echo "Installing mumble-web..."
    npm install mumble-web --prefix "$HOME" 2>/dev/null
else
    echo -e "${GREEN}✓ mumble-web already installed${NC}"
fi

echo ""
echo -e "${YELLOW}Generating SSL certificates...${NC}"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/server.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=$ACCESS_IP"
fi
echo -e "${GREEN}✓ Certificates ready${NC}"

echo ""
echo -e "${YELLOW}Configuring mumble-web...${NC}"
cat > "$HOME/node_modules/mumble-web/dist/config.local.js" << EOF
window.mumbleWebConfig.defaults['port'] = '$WS_PORT';
window.mumbleWebConfig.defaults['address'] = '$ACCESS_IP';
window.mumbleWebConfig.settings['voiceMode'] = 'ptt';
window.mumbleWebConfig.settings['pttKey'] = 'space';
EOF

echo ""
echo -e "${YELLOW}Clearing bans and starting mumble-server...${NC}"
sudo sqlite3 /var/lib/mumble-server/mumble-server.sqlite "DELETE FROM bans;" 2>/dev/null || true
sudo systemctl restart mumble-server
sleep 2

echo ""
echo -e "${YELLOW}Setting up systemd service...${NC}"

WEBSOCKIFY_BIN=$(which websockify 2>/dev/null || echo "$HOME/.local/bin/websockify")

sudo tee /etc/systemd/system/mumble-ptt-web.service > /dev/null << EOF
[Unit]
Description=Mumble PTT WebSocket Proxy
After=mumble-server.service

[Service]
ExecStart=$WEBSOCKIFY_BIN --web $HOME/node_modules/mumble-web/dist --cert=$CERT_DIR/server.crt --key=$CERT_DIR/server.key --ssl-target $WS_PORT 127.0.0.1:$MUMBLE_PORT
Restart=always
RestartSec=5
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mumble-ptt-web
sudo systemctl restart mumble-ptt-web
sleep 2

if sudo systemctl is-active --quiet mumble-ptt-web; then
    echo -e "${GREEN}✓ PTT service running${NC}"
else
    echo -e "${RED}✗ PTT service failed — check: sudo journalctl -u mumble-ptt-web -n 20${NC}"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}  ✓ Setup Complete!${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "  ${GREEN}Access URL:${NC} https://$ACCESS_IP:$WS_PORT"
echo ""
echo -e "  ${YELLOW}Chrome mic fix (once per client):${NC}"
echo -e "  chrome://flags/#unsafely-treat-insecure-origin-as-secure"
echo -e "  Add: https://$ACCESS_IP:$WS_PORT"
echo ""
echo -e "  ${YELLOW}PTT Key:${NC} Space bar (hold to talk)"
echo ""
