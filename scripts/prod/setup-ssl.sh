#!/usr/bin/env bash
# ==============================================================================
# setup-ssl.sh — obtain FREE Let's Encrypt certificates (certbot) and wire them
# into the production nginx (deploy/nginx/prod/nginx.conf).
#
# Requirements:
#   - DNS for api.<apex> and <apex> already point at this host,
#     and ports 80/443 are reachable (ufw allow 80,443/tcp).
#   - The HTTP catch-all in sites-available/mogok-maung exposes
#     /.well-known/acme-challenge/ with webroot /var/www/certbot — certbot
#     renews with zero downtime.
#   - Run as root (or with sudo).
# ==============================================================================
set -euo pipefail

EMAIL=${EMAIL:?set your real email, e.g. EMAIL=admin@oddsmyanmar.online}
# ONE combined cert covers both names (SAN). Stored by certbot under
# /etc/letsencrypt/live/<apex>/ — both nginx server blocks use it.
DOMAINS=${DOMAINS:-"oddsmyanmar.online api.oddsmyanmar.online"}
APEX="${DOMAINS%% *}"

apt-get update -y
apt-get install -y nginx openssl

# certbot (snap is the officially recommended path).
if [ ! -x /usr/bin/certbot ] && [ ! -x /snap/bin/certbot ]; then
    apt-get remove -y certbot 2>/dev/null || true
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# Install the production edge config (guardrail http level + vhosts).
cp -f infrastructure/nginx/cloudflare-ips.conf   /etc/nginx/cloudflare-ips.conf
cp -f infrastructure/nginx/admin-whitelist.conf  /etc/nginx/admin-whitelist.conf
cp -f infrastructure/nginx/cloudflared-ips.conf  /etc/nginx/cloudflared-ips.conf
cp -f deploy/nginx/prod/nginx.conf               /etc/nginx/nginx.conf
install -d /etc/nginx/sites-available
# Generate the vhosts from the repo template with the CONFIGURED domain pair
# substituted (server_name + ssl cert paths follow <apex>). Safe for any
# DOMAINS override.
sed -e "s/mmrodds\\.com/${APEX}/g" -e "s/oddsmyanmar\\.online/${APEX}/g" \
    deploy/nginx/prod/sites-available/mogok-maung > /etc/nginx/sites-available/mogok-maung
ln -sf /etc/nginx/sites-available/mogok-maung /etc/nginx/sites-enabled/mogok-maung
# Ubuntu ships a default server on :80 (default_server) that collides with our
# ACME catch-all — drop it so only the Mogok Maung vhosts listen.
rm -f /etc/nginx/sites-enabled/default

mkdir -p /var/www/certbot

echo "[certbot] obtaining certificates for: ${DOMAINS} (webroot)..."
certbot certonly --webroot -w /var/www/certbot \
    --non-interactive \
    --agree-tos \
    -m "${EMAIL}" \
    -d "${DOMAINS// / -d }"

nginx -t
systemctl reload nginx

echo "[certbot] certbot renewal timer:"
systemctl enable --now snap.certbot.renew.timer 2>/dev/null || systemctl enable --now certbot.timer

echo "[ssl] done — https://api.<apex> (API) and https://<apex> (SPA) are live (auto-renew via systemd timer): ${DOMAINS}"