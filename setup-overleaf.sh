#!/bin/bash
# Usage: sudo DOMAIN=<domain> LETSENCRYPT_EMAIL=<email> ./setup-overleaf.sh
set -Eeuo pipefail

DOMAIN="${DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
DATA_DIR="${DATA_DIR:-/srv/overleaf}"
OVERLEAF_USER="${OVERLEAF_USER:-overleaf}"
OVERLEAF_PORT="${OVERLEAF_PORT:-18080}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/overleaf-backups}"
SKIP_CERTBOT="${SKIP_CERTBOT:-false}"

TOOLKIT_DIR="/home/${OVERLEAF_USER}/overleaf-toolkit"
BUILD_DIR="/home/${OVERLEAF_USER}/overleaf-src"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this as root (e.g. with sudo)."
[ -n "$DOMAIN" ] || die "Set DOMAIN, e.g. DOMAIN=latex.example.com."
if [ "$SKIP_CERTBOT" != "true" ] && [ -z "$LETSENCRYPT_EMAIL" ]; then
    die "Set LETSENCRYPT_EMAIL, or SKIP_CERTBOT=true for HTTP-only/VPN setups."
fi

ARCH="$(dpkg --print-architecture)"

apt-get update
apt-get install -y \
    ca-certificates curl gnupg git make \
    nginx certbot python3-certbot-nginx \
    unattended-upgrades

if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp
    ufw allow 443/tcp
fi

if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    . /etc/os-release
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

id -u "$OVERLEAF_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$OVERLEAF_USER"
usermod -aG docker "$OVERLEAF_USER"

mkdir -p "${DATA_DIR}"/{overleaf,mongo,redis}
chown -R "${OVERLEAF_USER}:${OVERLEAF_USER}" "$DATA_DIR"

if [ ! -d "$TOOLKIT_DIR" ]; then
    sudo -u "$OVERLEAF_USER" git clone --depth 1 \
        https://github.com/overleaf/toolkit.git "$TOOLKIT_DIR"
fi
cd "$TOOLKIT_DIR"
[ -f config/overleaf.rc ] || sudo -u "$OVERLEAF_USER" bin/init

TOOLKIT_VERSION="$(cat config/version)"

sudo -u "$OVERLEAF_USER" tee config/overleaf.rc >/dev/null <<EOF
OVERLEAF_DATA_PATH=${DATA_DIR}/overleaf
OVERLEAF_LISTEN_IP=127.0.0.1
OVERLEAF_PORT=${OVERLEAF_PORT}
SIBLING_CONTAINERS_ENABLED=false
MONGO_DATA_PATH=${DATA_DIR}/mongo
REDIS_DATA_PATH=${DATA_DIR}/redis
EOF

sudo -u "$OVERLEAF_USER" touch config/variables.env
sudo -u "$OVERLEAF_USER" sed -i \
    -e '/^OVERLEAF_SITE_URL=/d' \
    -e '/^OVERLEAF_BEHIND_PROXY=/d' \
    -e '/^OVERLEAF_SECURE_COOKIE=/d' \
    -e '/^EMAIL_CONFIRMATION_DISABLED=/d' \
    config/variables.env
sudo -u "$OVERLEAF_USER" tee -a config/variables.env >/dev/null <<EOF
OVERLEAF_SITE_URL=https://${DOMAIN}
OVERLEAF_BEHIND_PROXY=true
OVERLEAF_SECURE_COOKIE=true
# No SMTP configured; see README.md "Outgoing mail" to enable it.
EMAIL_CONFIRMATION_DISABLED=true
EOF

# arm64: no official image upstream, build Community Edition from source.
if [ "$ARCH" = "arm64" ]; then
    if [ ! -d "$BUILD_DIR" ]; then
        sudo -u "$OVERLEAF_USER" git clone --depth 1 \
            https://github.com/overleaf/overleaf.git "$BUILD_DIR"
    fi

    sudo -u "$OVERLEAF_USER" bash -lc "
        set -Eeuo pipefail
        cd '${BUILD_DIR}/server-ce'
        export DOCKER_BUILDKIT=1
        make BRANCH_NAME=arm64 build-base
        make BRANCH_NAME=arm64 build-community
    "
    docker tag sharelatex/sharelatex:arm64 "sharelatex/sharelatex:${TOOLKIT_VERSION}"
fi

sudo -u "$OVERLEAF_USER" bash -lc "cd '${TOOLKIT_DIR}' && ./bin/up -d"
sleep 10

rm -f /etc/nginx/sites-enabled/default

SITE_CONF="/etc/nginx/sites-available/${DOMAIN}"
tee "$SITE_CONF" >/dev/null <<NGINX
limit_req_zone \$binary_remote_addr zone=overleaf_login:10m rate=5r/m;

server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    client_max_body_size 100M;

    location = /login {
        limit_req zone=overleaf_login burst=5 nodelay;
        limit_req_status 429;

        proxy_pass http://127.0.0.1:${OVERLEAF_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    location / {
        proxy_pass http://127.0.0.1:${OVERLEAF_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
NGINX
ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/

# Reject requests for any hostname other than $DOMAIN.
tee /etc/nginx/sites-available/00-default-reject >/dev/null <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
ln -sf /etc/nginx/sites-available/00-default-reject /etc/nginx/sites-enabled/

nginx -t
systemctl reload nginx

if [ "$SKIP_CERTBOT" != "true" ]; then
    certbot --nginx -d "$DOMAIN" -m "$LETSENCRYPT_EMAIL" \
        --agree-tos --redirect --non-interactive
    nginx -t
    systemctl reload nginx
fi

install -m 0755 "${SCRIPT_DIR}/overleaf-backup.sh" /usr/local/sbin/overleaf-backup
mkdir -p "$BACKUP_ROOT"
chown root:root "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

tee /etc/systemd/system/overleaf-backup.service >/dev/null <<EOF
[Unit]
Description=Overleaf backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
Environment=DATA_DIR=${DATA_DIR}
Environment=TOOLKIT_DIR=${TOOLKIT_DIR}
Environment=BACKUP_ROOT=${BACKUP_ROOT}
ExecStart=/usr/local/sbin/overleaf-backup
EOF

tee /etc/systemd/system/overleaf-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly Overleaf backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now overleaf-backup.timer
