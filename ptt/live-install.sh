#!/usr/bin/env bash
set -e

echo "Creating LiveKit stack..."

mkdir -p livekit-stack/web
mkdir -p livekit-stack/token-server

# -------------------------
# LiveKit config
# -------------------------
cat > livekit-stack/livekit.yaml << 'EOF'
port: 7880

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000

keys:
  devkey: secret

logging:
  level: info

development: true
EOF

# -------------------------
# docker-compose
# -------------------------
cat > livekit-stack/docker-compose.yml << 'EOF'
version: "3.9"

services:

  livekit:
    image: livekit/livekit-server:latest
    container_name: livekit
    command: --config /etc/livekit.yaml
    ports:
      - "7880:7880"
      - "7881:7881"
      - "50000-60000:50000-60000/udp"
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml
    restart: unless-stopped

  web:
    build: ./web
    container_name: livekit-web
    ports:
      - "8080:80"
    restart: unless-stopped

  token-server:
    build: ./token-server
    container_name: livekit-token
    ports:
      - "3000:3000"
    restart: unless-stopped
EOF

# -------------------------
# Web Dockerfile
# -------------------------
cat > livekit-stack/web/Dockerfile << 'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EOF

# -------------------------
# Web client
# -------------------------
cat > livekit-stack/web/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>LiveKit PTT</title>
</head>
<body>

<h2>PTT System</h2>

<button id="connect">Connect</button>
<button id="ptt">PTT</button>

<script type="module">
import {
  Room,
  RoomEvent,
  createLocalTracks
} from "https://esm.sh/livekit-client";

const URL = "ws://YOUR_SERVER_IP:7880";

let room;
let micTrack;

async function getToken(identity) {
  const res = await fetch(`http://YOUR_SERVER_IP:3000/token?identity=${identity}`);
  const data = await res.json();
  return data.token;
}

document.getElementById("connect").onclick = async () => {
  const TOKEN = await getToken("operator1");

  room = new Room();

  room.on(RoomEvent.TrackSubscribed, (track) => {
    if (track.kind === "audio") {
      const el = track.attach();
      document.body.appendChild(el);
      el.play();
    }
  });

  await room.connect(URL, TOKEN);

  const tracks = await createLocalTracks({ audio: true });
  micTrack = tracks.find(t => t.kind === "audio");

  await room.localParticipant.publishTrack(micTrack);

  console.log("connected");
};

document.getElementById("ptt").onmousedown = () => {
  micTrack?.setEnabled(true);
};

document.getElementById("ptt").onmouseup = () => {
  micTrack?.setEnabled(false);
};
</script>

</body>
</html>
EOF

# -------------------------
# Token server
# -------------------------
cat > livekit-stack/token-server/package.json << 'EOF'
{
  "name": "livekit-token-server",
  "type": "module",
  "dependencies": {
    "express": "^4.18.2",
    "livekit-server-sdk": "^2.0.0",
    "cors": "^2.8.5"
  }
}
EOF

cat > livekit-stack/token-server/server.js << 'EOF'
import express from "express";
import cors from "cors";
import { AccessToken } from "livekit-server-sdk";

const app = express();
app.use(cors());
app.use(express.json());

const API_KEY = "devkey";
const API_SECRET = "secret";

app.get("/token", (req, res) => {
  const identity = req.query.identity || "user";

  const at = new AccessToken(API_KEY, API_SECRET, {
    identity
  });

  at.addGrant({
    roomJoin: true,
    room: "test"
  });

  res.json({ token: at.toJwt() });
});

app.listen(3000, () => {
  console.log("Token server running on :3000");
});
EOF

# -------------------------
# Token server Dockerfile
# -------------------------
cat > livekit-stack/token-server/Dockerfile << 'EOF'
FROM node:20

WORKDIR /app
COPY package.json .
RUN npm install

COPY server.js .

CMD ["node", "server.js"]
EOF

# -------------------------
# Done
# -------------------------
echo ""
echo "DONE ✔"
echo ""
echo "Next steps:"
echo "1. cd livekit-stack"
echo "2. docker compose up -d --build"
echo "3. Open http://SERVER_IP:8080"
echo ""
echo "IMPORTANT:"
echo "- Replace YOUR_SERVER_IP in web/index.html"
echo ""
