#!/usr/bin/env bash
# ============================================================
# godseye.sh v2 — God's Eye View @ https://godseye.fluxlab.agency
# Repo: github.com/fluxopss/vps-bootstrap
# Run:  curl -fsSL https://raw.githubusercontent.com/fluxopss/vps-bootstrap/main/godseye.sh | bash
# Stack: Docker build -> Traefik route (same pattern as sign/gc/pulse) + auto SSL
# Fallback: loopback container + cloudflared temp URL if no Traefik found
# ============================================================
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root (sudo -i first)."; exit 1; }

HOST="godseye.fluxlab.agency"
APP_DIR=/opt/gods-eye-view
PORT=4173

echo "==> [1/6] Deps"
apt-get update -y
apt-get install -y git curl ca-certificates
command -v docker >/dev/null 2>&1 || { echo "Docker not found; aborting (VM template should include it)."; exit 1; }

echo "==> [2/6] Clone bilawalsidhu/gods-eye-view"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone https://github.com/bilawalsidhu/gods-eye-view.git "$APP_DIR"
fi
cd "$APP_DIR"

echo "==> [3/6] Docker build (Node 24, keyless)"
cat > flux.Dockerfile <<'DOCKER'
FROM node:24-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
EXPOSE 4173
CMD ["npm","run","dev","--","--host","0.0.0.0","--port","4173"]
DOCKER
printf 'node_modules\n.git\n' > .dockerignore
docker build -f flux.Dockerfile -t godseye:latest .

echo "==> [4/6] Detect Traefik"
TRAEFIK="$(docker ps --format '{{.Names}}' | grep -im1 traefik || true)"
NET=""
EP="websecure"
RESOLVER="letsencrypt"
if [ -n "$TRAEFIK" ]; then
  NET="$(docker inspect "$TRAEFIK" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | { grep -Eim1 'proxy|web|front|traefik|edge|public' || head -n1; })"
  R="$(docker inspect "$TRAEFIK" --format '{{json .Config.Cmd}}{{json .Args}}' | grep -oE 'certificatesresolvers\.[A-Za-z0-9_-]+' | head -n1 | cut -d. -f2)"
  [ -n "$R" ] && RESOLVER="$R"
  E="$(docker inspect "$TRAEFIK" --format '{{json .Config.Cmd}}{{json .Args}}' | grep -oE 'entrypoints\.[A-Za-z0-9_-]+\.address=:443' | head -n1 | cut -d. -f2)"
  [ -n "$E" ] && EP="$E"
  echo "    traefik=$TRAEFIK network=$NET entrypoint=$EP resolver=$RESOLVER"
fi

echo "==> [5/6] Launch container"
docker rm -f godseye >/dev/null 2>&1 || true
if [ -n "$TRAEFIK" ]; then
  docker run -d --name godseye --restart unless-stopped --network "$NET" \
    --label traefik.enable=true \
    --label "traefik.http.routers.godseye.rule=Host(\`$HOST\`)" \
    --label traefik.http.routers.godseye.entrypoints="$EP" \
    --label traefik.http.routers.godseye.tls=true \
    --label "traefik.http.routers.godseye.tls.certresolver=$RESOLVER" \
    --label traefik.http.services.godseye.loadbalancer.server.port="$PORT" \
    godseye:latest
else
  echo "    WARNING: no Traefik container detected — loopback + cloudflared fallback"
  docker run -d --name godseye --restart unless-stopped -p 127.0.0.1:$PORT:$PORT godseye:latest
  if ! command -v cloudflared >/dev/null 2>&1; then
    curl -fsSL -o /tmp/cloudflared.deb \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb
  fi
  pkill -f 'cloudflared tunnel --url' 2>/dev/null || true
  nohup cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
    >/var/log/godseye-tunnel.log 2>&1 &
fi

echo "==> [6/6] Verify"
sleep 8
docker logs godseye 2>&1 | tail -3
if [ -n "$TRAEFIK" ]; then
  for i in 1 2 3 4 5 6; do
    sleep 10
    if curl -fsS -k --resolve "$HOST:443:127.0.0.1" "https://$HOST" -o /tmp/godseye-check.html; then
      echo ""
      echo "============================================"
      echo "  GOD'S EYE IS LIVE: https://$HOST"
      echo "  (cert auto-issued via Traefik)"
      echo "============================================"
      head -c 200 /tmp/godseye-check.html; echo ""
      exit 0
    fi
  done
  echo "Route not answering yet — cert may still be issuing. Re-check:  curl -sk --resolve $HOST:443:127.0.0.1 https://$HOST | head"
else
  sleep 12
  echo "================ TEMP URL ================"
  grep -o 'https://[A-Za-z0-9.-]*trycloudflare.com' /var/log/godseye-tunnel.log | head -1 \
    || echo "Tunnel URL pending — run: tail -f /var/log/godseye-tunnel.log"
fi
echo "Kill later with:  docker rm -f godseye && rm -rf $APP_DIR"
