# Self-hosting Overleaf Community Edition

A tested, reasonably hardened setup for running [Overleaf Community
Edition](https://github.com/overleaf/overleaf) on your own server, including
a workaround for hosts without an official Docker image (notably arm64/aarch64
VPS instances such as Ampere/Oracle Cloud, Hetzner arm64, or Raspberry Pi).

There are two ways to use this repo:

- Run `scripts/setup-overleaf.sh` and get a working instance in one pass.
- Follow the [manual guide](#manual-step-by-step-guide) below, which does
  the same thing command by command, if you want to understand or customize
  each step.

## Contents

- [Read this first: Community Edition's security model](#read-this-first-community-editions-security-model)
- [Architecture](#architecture)
- [The arm64 problem](#the-arm64-problem)
- [Requirements](#requirements)
- [Quick start (script)](#quick-start)
- [Manual step-by-step guide](#manual-step-by-step-guide)
- [Outgoing mail](#outgoing-mail)
- [Backups and restore](#backups-and-restore)
- [Updating](#updating)
- [Things this setup deliberately does not do](#things-this-setup-deliberately-does-not-do)
- [References](#references)

## Read this first: Community Edition's security model

Overleaf CE assumes all users are trusted. Unlike Server Pro, it does not run
LaTeX compilation in an isolated sandbox container (compilation happens in
the same container as the rest of the application). This is a property of CE
itself, not a gap in this setup.

| Who will use it | Recommendation |
|---|---|
| Just you | Fine, with the isolation below |
| A handful of trusted colleagues | Fine, with the isolation below |
| Public registration / untrusted users | Do not use CE for this |

Practical mitigations (all included below): keep the instance off public
registration, run it as an unprivileged Docker deployment with no
Docker-socket access from the application container, isolate it on its own
VM/host if possible, and don't put it in front of untrusted users.

## Architecture

```
Internet
   |
   |  HTTPS (443), rate-limited login, unknown hosts rejected
   v
Nginx (host), Let's Encrypt via Certbot
   |
   |  127.0.0.1:<port>
   v
Overleaf (Docker, via the official Toolkit)
   |
   +-- MongoDB (private Docker network, no published port)
   +-- Redis   (private Docker network, no published port)

Nightly: mongodump + filesystem snapshot -> /srv/overleaf-backups
```

Only Nginx is exposed publicly. MongoDB, Redis, and the Overleaf application
port are bound to `127.0.0.1` only.

## The arm64 problem

Overleaf's official `sharelatex/sharelatex` image is published for `amd64`
only. On an arm64 host, `bin/up` fails with:

```
no matching manifest for linux/arm64/v8 in the manifest list entries
```

Overleaf's Dockerfiles do build correctly on arm64, they're just not
published for that architecture (tracked in [overleaf/overleaf#881](https://github.com/overleaf/overleaf/issues/881)).
The fix is to build the image yourself from the official source and tag it
with the version the Toolkit expects. This is covered in detail in
[step 7 of the manual guide](#7-arm64-only-build-the-image-locally), and
handled automatically by the setup script.

## Requirements

- A Debian or Ubuntu server (tested on Debian 12), root/sudo access
- A domain name with an A/AAAA record pointing at the server (or skip TLS
  and put the server behind a VPN, see `SKIP_CERTBOT` below)
- Ports 80 and 443 reachable from the internet if you want public HTTPS

## Quick start

```bash
git clone <this-repo>
cd overleaf-selfhost
sudo DOMAIN=latex.example.com LETSENCRYPT_EMAIL=you@example.com \
    ./scripts/setup-overleaf.sh
```

For a VPN-only instance with no public exposure, skip Certbot and put a VPN
(WireGuard/Tailscale) in front instead:

```bash
sudo DOMAIN=latex.internal SKIP_CERTBOT=true ./scripts/setup-overleaf.sh
```

Re-running the script is mostly safe: it skips steps whose state already
exists (Docker, the Toolkit clone, the arm64 build directory) and rewrites
its own config files idempotently. It still makes live changes each time
(firewall rules, Nginx reload, container recreation), so don't run it
against a server you're actively debugging without reading it first.

### After the script finishes

1. Open `https://<domain>/launchpad` and create the first admin account.
   This route only works before any admin exists.
2. Log in, then create accounts for your colleagues from `/admin/register`
   rather than leaving `/register` open to the public.
3. Run `sudo -u overleaf /home/overleaf/overleaf-toolkit/bin/doctor` to
   sanity-check the deployment.
4. Trigger one manual backup and confirm it completes:
   `sudo systemctl start overleaf-backup.service && sudo journalctl -u overleaf-backup.service -n 50`

## Manual step-by-step guide

Everything the script does, as individual commands. Each step links to the
relevant upstream documentation. Substitute your own domain/paths for
`latex.example.com`, `/srv/overleaf`, and `overleaf` (the system user)
throughout.

### 1. Firewall rules

This guide doesn't assume any particular firewall setup, since that's
specific to your host and easy to get wrong from the outside (an existing
policy, a cloud provider firewall in front of the VM, and so on). Whatever
you use, make sure these are allowed inbound:

- `80/tcp` (HTTP: the Let's Encrypt challenge and the redirect to HTTPS)
- `443/tcp` (HTTPS)

If you use `ufw`:

```bash
sudo apt update
sudo apt install -y ufw unattended-upgrades
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

### 2. Install Docker Engine

Follow Docker's official instructions for your distribution rather than the
`docker.io` package from the OS repos, so you get Compose v2 and Buildx:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
```

See [11] for the full install matrix across distributions.

### 3. Create a dedicated user and data directories

Run Overleaf as its own system user rather than your login account, and
keep its data outside the Toolkit checkout so backups and permissions stay
simple:

```bash
sudo useradd -m -s /bin/bash overleaf
sudo usermod -aG docker overleaf

sudo mkdir -p /srv/overleaf/{overleaf,mongo,redis}
sudo chown -R overleaf:overleaf /srv/overleaf
```

### 4. Install the Overleaf Toolkit

```bash
sudo -u overleaf git clone --depth 1 \
    https://github.com/overleaf/toolkit.git /home/overleaf/overleaf-toolkit
cd /home/overleaf/overleaf-toolkit
sudo -u overleaf bin/init
cat config/version   # the release tag the Toolkit expects, e.g. 6.3.0
```

[1][3]

### 5. Point the Toolkit at your data directories

Edit `config/overleaf.rc`:

```ini
OVERLEAF_DATA_PATH=/srv/overleaf/overleaf
OVERLEAF_LISTEN_IP=127.0.0.1
OVERLEAF_PORT=18080
SIBLING_CONTAINERS_ENABLED=false
MONGO_DATA_PATH=/srv/overleaf/mongo
REDIS_DATA_PATH=/srv/overleaf/redis
```

`SIBLING_CONTAINERS_ENABLED=false` matters: that setting exists for Server
Pro's sandboxed-compile feature, which mounts the Docker socket into the
application container. It provides no benefit in CE and only adds attack
surface, so leave it off.

`OVERLEAF_PORT=18080` (rather than 80) leaves the standard port free for
Nginx, which will be the only thing listening publicly.

[4][6]

### 6. Configure the reverse-proxy variables

Append to `config/variables.env` (not `overleaf.rc`; these are read into the
container as environment variables):

```bash
cat >> config/variables.env <<'EOF'
OVERLEAF_SITE_URL=https://latex.example.com
OVERLEAF_BEHIND_PROXY=true
OVERLEAF_SECURE_COOKIE=true
EOF
```

`OVERLEAF_SITE_URL` controls the links and WebSocket origin Overleaf
generates; `OVERLEAF_BEHIND_PROXY` and `OVERLEAF_SECURE_COOKIE` tell it TLS
is terminated upstream, so it can issue a `Secure` session cookie. Without
these, the session cookie is missing `Secure` even over HTTPS.

[5]

### 7. arm64 only: build the image locally

Skip this step entirely on amd64; the official image will be pulled as
normal by `bin/up`.

On arm64/aarch64, build Overleaf's own source instead of pulling the
(amd64-only) published image:

```bash
sudo -u overleaf git clone --depth 1 \
    https://github.com/overleaf/overleaf.git /home/overleaf/overleaf-src
cd /home/overleaf/overleaf-src/server-ce

export DOCKER_BUILDKIT=1     # the Dockerfiles use --mount=type=cache, which needs BuildKit
sudo -u overleaf --preserve-env=DOCKER_BUILDKIT \
    make BRANCH_NAME=arm64 build-base
sudo -u overleaf --preserve-env=DOCKER_BUILDKIT \
    make BRANCH_NAME=arm64 build-community
```

`BRANCH_NAME=arm64` works around a Makefile detail: the image tag is derived
from the current git branch name, and Docker rejects tags containing `/`
(which the checked-out branch may contain). Overriding it avoids that
without touching the upstream source.

Once both builds finish, tag the result with the version your Toolkit
checkout expects (from `config/version` in step 4):

```bash
docker tag sharelatex/sharelatex:arm64 sharelatex/sharelatex:6.3.0
docker image inspect sharelatex/sharelatex:6.3.0 \
    --format 'ID={{.Id}} ARCH={{.Architecture}} OS={{.Os}}'
```

Confirm the Toolkit will actually use this local image before starting
anything:

```bash
cd /home/overleaf/overleaf-toolkit
sudo -u overleaf ./bin/docker-compose config | grep -A3 -B3 'sharelatex/sharelatex'
```

You should see `image: sharelatex/sharelatex:6.3.0` and nothing indicating
Docker will try to pull it.

Keep in mind this image is built from upstream `main` at build time, tagged
as if it were the numbered release. It is not a byte-for-byte copy of the
official release artifact; rebuild and re-tag it whenever you upgrade the
Toolkit.

[2][9][10]

### 8. Start Overleaf

```bash
cd /home/overleaf/overleaf-toolkit
sudo -u overleaf ./bin/up -d
docker ps
docker logs --tail 50 sharelatex
```

Confirm it responds locally before exposing it:

```bash
curl -I http://127.0.0.1:18080/
```

A `302` redirect to `/login` means it's up.

### 9. Configure Nginx as the public-facing proxy

```bash
sudo apt install -y nginx certbot python3-certbot-nginx
sudo rm -f /etc/nginx/sites-enabled/default
```

Create `/etc/nginx/sites-available/latex.example.com`:

```nginx
limit_req_zone $binary_remote_addr zone=overleaf_login:10m rate=5r/m;

server {
    listen 80;
    listen [::]:80;
    server_name latex.example.com;
    client_max_body_size 100M;

    location = /login {
        limit_req zone=overleaf_login burst=5 nodelay;
        limit_req_status 429;

        proxy_pass http://127.0.0.1:18080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    location / {
        proxy_pass http://127.0.0.1:18080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
```

The `Upgrade`/`Connection` headers are required for Overleaf's real-time
collaboration (WebSockets). The `limit_req` block on `/login` throttles
brute-force attempts to about 5 requests/minute per IP without blocking
normal use (loading the page plus submitting credentials).

Enable it and add a catch-all vhost that rejects any request for a hostname
other than yours, instead of letting Nginx answer with the Overleaf vhost
for arbitrary `Host` headers or the bare IP:

```bash
sudo ln -s /etc/nginx/sites-available/latex.example.com /etc/nginx/sites-enabled/

sudo tee /etc/nginx/sites-available/00-default-reject >/dev/null <<'EOF'
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
sudo ln -s /etc/nginx/sites-available/00-default-reject /etc/nginx/sites-enabled/

sudo nginx -t
sudo systemctl reload nginx
```

`ssl_reject_handshake` needs nginx >= 1.19.4 (Debian 12's 1.22.1 qualifies);
it rejects the TLS handshake outright for unrecognized hostnames rather than
presenting your certificate to them.

[12]

### 10. Get a certificate

```bash
sudo certbot --nginx -d latex.example.com
```

Choose to redirect HTTP to HTTPS when prompted. Certbot edits the site file
in place, adding the `listen 443 ssl` and certificate directives to the
same server block (your `/login` and `/` locations are left untouched) and
creating a separate HTTP-to-HTTPS redirect block.

Verify:

```bash
curl -sSI https://latex.example.com/ | grep -iE 'HTTP/|set-cookie:'
```

The session cookie should now include `Secure`. Test renewal:

```bash
sudo certbot renew --dry-run
```

[13]

### 11. Set up backups

```bash
sudo install -m 0755 scripts/overleaf-backup.sh /usr/local/sbin/overleaf-backup
sudo mkdir -p /srv/overleaf-backups
sudo chown root:root /srv/overleaf-backups
sudo chmod 700 /srv/overleaf-backups
```

Install the systemd service and nightly timer:

```bash
sudo tee /etc/systemd/system/overleaf-backup.service >/dev/null <<'EOF'
[Unit]
Description=Overleaf backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/overleaf-backup
EOF

sudo tee /etc/systemd/system/overleaf-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly Overleaf backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now overleaf-backup.timer
sudo systemctl start overleaf-backup.service   # run once now to check it works
sudo journalctl -u overleaf-backup.service -n 50
```

[8]

### 12. Create the first account and close registration

```
https://latex.example.com/launchpad
```

only works before any admin account exists; use it to create yours. After
logging in, create accounts for colleagues from `/admin/register` instead of
leaving public sign-up open.

That completes the same result as `scripts/setup-overleaf.sh`.

## Outgoing mail

The setup above leaves `EMAIL_CONFIRMATION_DISABLED=true` and does not
configure an SMTP backend, since that (mail server, SPF/DKIM/DMARC records)
is specific to your domain and mail provider. If you want Overleaf to send
invite/password-reset emails, configure the `OVERLEAF_EMAIL_*` variables in
`config/variables.env` against your own SMTP provider or mail server, then
remove the `EMAIL_CONFIRMATION_DISABLED` line. See [7] for the variable
names.

## Backups and restore

Backups land in `/srv/overleaf-backups/<timestamp>/` and contain:

- `mongo.archive.gz`: a `mongodump --archive --gzip` of MongoDB
- `overleaf.tar.zst`: the Overleaf data directory
- `redis.tar.zst`: the Redis data directory
- `toolkit-config.tar.zst`: the Toolkit's `config/` directory

To restore: stop the stack (`bin/docker-compose down`), extract the
`overleaf.tar.zst`/`redis.tar.zst` archives back into the data directory,
start MongoDB only and `mongorestore --archive --gzip` into it, then start
the rest with `bin/up -d`. Test this before you need it; a backup that has
never been restored is unverified.

Backups are kept for 7 days locally by default (`RETENTION_DAYS` in
`scripts/overleaf-backup.sh`). Copy them off the server (encrypted) for real
disaster recovery; a backup stored only on the machine it protects doesn't
protect against losing that machine.

## Updating

Follow the Toolkit's own upgrade process: pull the latest Toolkit, read its
release notes, update `config/version`, and re-run `bin/upgrade` /
`bin/up -d`. On arm64, rebuild and re-tag the image first (step 7 above) so
it matches the new `config/version` before starting the upgraded stack.

## Things this setup deliberately does not do

- It does not sandbox LaTeX compilation (see the security note above).
- It does not configure outgoing mail.
- It does not set up a VPN. If you want VPN-only access, run with
  `SKIP_CERTBOT=true` and put WireGuard or Tailscale in front yourself.
- It does not manage secrets for you. `config/variables.env` will contain
  session/invite secrets; keep it out of version control (add it to
  `.gitignore` if you fork the Toolkit config into a repo), and rotate any
  secret you think may have leaked.

## Files

- `scripts/setup-overleaf.sh`: the automated setup described above
- `scripts/overleaf-backup.sh`: the backup script installed by setup

## References

Cited by number (`[n]`) at the points above where the reasoning isn't
self-explanatory from the command alone.

| # | Topic | Link |
|---|---|---|
| [1] | Overleaf Toolkit | <https://github.com/overleaf/toolkit> |
| [2] | Overleaf source (server-ce) | <https://github.com/overleaf/overleaf> |
| [3] | Toolkit installation guide | <https://docs.overleaf.com/on-premises/installation/introduction> |
| [4] | Toolkit environment variables | <https://docs.overleaf.com/on-premises/configuration/overleaf-toolkit/environment-variables> |
| [5] | TLS proxy configuration | <https://docs.overleaf.com/on-premises/configuration/overleaf-toolkit/tls-proxy> |
| [6] | Sandboxed compiles (Server Pro) | <https://docs.overleaf.com/on-premises/configuration/overleaf-toolkit/server-pro-only-configuration/sandboxed-compiles> |
| [7] | Email delivery | <https://docs.overleaf.com/on-premises/configuration/overleaf-toolkit/email-delivery> |
| [8] | Data and backups | <https://docs.overleaf.com/on-premises/maintenance/data-and-backups> |
| [9] | arm64 tracking issue | <https://github.com/overleaf/overleaf/issues/881> |
| [10] | Docker BuildKit | <https://docs.docker.com/build/buildkit/> |
| [11] | Docker Engine install | <https://docs.docker.com/engine/install/debian/> |
| [12] | nginx `limit_req` module | <https://nginx.org/en/docs/http/ngx_http_limit_req_module.html> |
| [13] | Certbot | <https://certbot.eff.org/instructions> |
