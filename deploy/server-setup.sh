#!/usr/bin/env bash
# Runs ON the EC2 server. Installs Python and Caddy, installs the app, and starts both.
# Safe to run again after copying new code.
#   bash ~/app/deploy/server-setup.sh 13-233-1-5.sslip.io
set -euo pipefail

DOMAIN="${1:?Usage: server-setup.sh <domain, for example 13-233-1-5.sslip.io>}"
APP_DIR="$HOME/app"
cd "$APP_DIR"

if [ ! -f .env ]; then
  echo "Missing $APP_DIR/.env. Copy the project (including .env) to the server first."
  exit 1
fi
chmod 600 .env

sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv caddy

[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt

sudo cp deploy/ai-interviewer.service /etc/systemd/system/ai-interviewer.service
sed "s/DOMAIN_PLACEHOLDER/$DOMAIN/" deploy/Caddyfile | sudo tee /etc/caddy/Caddyfile >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable ai-interviewer >/dev/null
sudo systemctl restart ai-interviewer
sudo systemctl enable caddy >/dev/null
sudo systemctl restart caddy

ok=""
for _ in $(seq 1 30); do   # the app can take several seconds to start on a small server
  if curl -fsS http://127.0.0.1:8000/api/v1/roles >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [ -n "$ok" ]; then
  echo "App is running. Open https://$DOMAIN (the HTTPS certificate can take up to a minute the first time)."
else
  echo "The app did not answer. See its logs with: sudo journalctl -u ai-interviewer -n 50"
  exit 1
fi
