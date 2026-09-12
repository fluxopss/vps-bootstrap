#!/usr/bin/env bash
# ============================================================
# Flux VPS bootstrap — God's Eye View temp URL
# Repo: github.com/fluxopss/vps-bootstrap
# Run:  curl -fsSL https://raw.githubusercontent.com/fluxopss/vps-bootstrap/main/godseye.sh | bash
# Target: srv1755892.hstgr.cloud (KVM 2, Ubuntu 24.04, 2.25.206.39)
# Result: systemd service on 127.0.0.1:4173 + cloudflared temp URL
# ============================================================
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root (sudo -i first)."; exit 1; }

APP_DIR=/opt/gods-eye-view
PORT=4173

echo "==> [1/5] System deps"
apt-get update -y
apt-get install -y git curl ca-certificates

echo "==> [2/5] Node.js 24 (repo requirement)"
if ! node -v 2>/dev/null | grep -q '^v24'; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi
node -v

echo "==> [3/5] Clone bilawalsidhu/gods-eye-view"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone https://github.com/bilawalsidhu/gods-eye-view.git "$APP_DIR"
fi
cd "$APP_DIR"
npm ci

echo "==> [4/5] systemd service (loopback-only; tunnel is the only door)"
cat >/etc/systemd/system/godseye.service <<EOF
[Unit]
Description=Gods Eye View (keyless demo)
After=network-online.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/npm run dev -- --host 127.0.0.1 --port $PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now godseye
sleep 6
systemctl is-active godseye
curl -fsS "http://127.0.0.1:$PORT" | head -c 300
echo ""
echo "    <- local OK"

echo "==> [5/5] cloudflared quick tunnel (temp public URL)"
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL -o /tmp/cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i /tmp/cloudflared.deb
fi
pkill -f 'cloudflared tunnel --url' 2>/dev/null || true
nohup cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
  >/var/log/godseye-tunnel.log 2>&1 &
sleep 12

echo ""
echo "================ TEMP URL ================"
grep -o 'https://[A-Za-z0-9.-]*trycloudflare.com' /var/log/godseye-tunnel.log | head -1 \
  || { echo "URL not ready yet — run: tail -f /var/log/godseye-tunnel.log"; exit 1; }
echo "==========================================="
echo "Share that URL back to Perplexity for live verification."
echo "Kill it later with:  systemctl stop godseye && pkill -f cloudflared"
