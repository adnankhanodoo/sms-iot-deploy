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
