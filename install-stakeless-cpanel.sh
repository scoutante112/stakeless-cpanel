#!/usr/bin/env bash
# =============================================================================
#  Stakeless på cPanel/WHM – casino.labnat.se (cPanel-användare: labnat)
#
#  Appen körs i Docker på 127.0.0.1:8798 och cPanels Apache proxar
#  subdomänen dit (inkl. WebSocket). AutoSSL sköter certifikatet.
#
#  Användning (som root på cPanel-servern):
#    ./install-stakeless-cpanel.sh               # installera allt
#    ./install-stakeless-cpanel.sh update        # hämta senaste koden och bygg om
#    ./install-stakeless-cpanel.sh admin <namn>  # gör en användare till admin
#    ./install-stakeless-cpanel.sh chips <namn> <antal>
#    ./install-stakeless-cpanel.sh logs | stop
#    ./install-stakeless-cpanel.sh proxy         # skriv om bara Apache-proxyn
#    ./install-stakeless-cpanel.sh lock          # lås sidan, bara du kommer in
#    ./install-stakeless-cpanel.sh unlock        # öppna sidan igen
#
#  Fungerar på cPanel för Ubuntu (22.04/24.04) och AlmaLinux/RHEL.
# =============================================================================
set -euo pipefail

CPUSER="${CPUSER:-labnat}"
SUB="${SUB:-casino}"
ROOTDOMAIN="${ROOTDOMAIN:-labnat.se}"
DOMAIN="$SUB.$ROOTDOMAIN"
PORT="${PORT:-8798}"
INSTALL_DIR="${INSTALL_DIR:-/opt/stakeless}"
REPO="${REPO:-https://github.com/CZ140/Stakeless.git}"

COMPOSE_FILE="$INSTALL_DIR/docker-compose.prod.yml"
ENV_FILE="$INSTALL_DIR/.env.prod"
USERDATA="/etc/apache2/conf.d/userdata"

green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
die()    { red "FEL: $*"; exit 1; }

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p stakeless "$@"; }

psql_exec() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  dc exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"
}

IS_DEB=0; command -v apt-get >/dev/null && IS_DEB=1

pkg_install() {
  if [[ $IS_DEB == 1 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null; then dnf install -y -q "$@"
  else yum install -y -q "$@"; fi
}

# EasyApache 4 heter olika på Ubuntu (bindestreck) och RHEL (understreck)
ea_pkg() {
  if [[ $IS_DEB == 1 ]]; then echo "ea-apache24-mod-${1//_/-}"; else echo "ea-apache24-mod_$1"; fi
}

apache_ctl() {
  local b
  for b in httpd apachectl apache2ctl /usr/sbin/httpd /usr/sbin/apache2; do
    command -v "$b" >/dev/null 2>&1 && { "$b" "$@"; return; }
  done
  die "Hittar inte Apache-binären"
}

# --------------------------------------------------------------------------- #
preflight() {
  [[ $EUID -eq 0 ]] || die "Kör som root."
  [[ -d /usr/local/cpanel ]] || die "Hittar inte cPanel på den här servern."
  [[ -f "/var/cpanel/users/$CPUSER" ]] || die "cPanel-användaren '$CPUSER' finns inte."
  command -v git >/dev/null || { [[ $IS_DEB == 1 ]] && apt-get update -qq; pkg_install git; }
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    green "==> Docker finns redan"
  else
    green "==> Installerar Docker CE"
    if [[ $IS_DEB == 1 ]]; then
      curl -fsSL https://get.docker.com | sh
    else
      pkg_install dnf-plugins-core || true
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
  fi

  # CSF rensar annars Dockers iptables-kedjor vid varje 'csf -r'
  if [[ -f /etc/csf/csf.conf ]]; then
    if grep -q '^DOCKER = "0"' /etc/csf/csf.conf; then
      green "==> Slår på Docker-stöd i CSF"
      sed -i 's/^DOCKER = "0"/DOCKER = "1"/' /etc/csf/csf.conf
      csf -r >/dev/null
    fi
  fi

  systemctl enable --now docker
  systemctl restart docker
}

fetch_code() {
  green "==> Hämtar koden till $INSTALL_DIR"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" stash -q || true
    git -C "$INSTALL_DIR" pull -q --ff-only
    git -C "$INSTALL_DIR" stash pop -q 2>/dev/null || true
  else
    git clone -q "$REPO" "$INSTALL_DIR"
  fi
  # SSL mot databasen styrs av DB_SSL istället för NODE_ENV (lokal Postgres har ingen SSL)
  local f="$INSTALL_DIR/apps/backend/src/db/index.ts"
  sed -i "s/ssl: env.NODE_ENV === 'production'/ssl: process.env.DB_SSL === 'true'/" "$f"
}

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    yellow "==> $ENV_FILE finns redan – behåller hemligheterna"
    return
  fi
  green "==> Skapar $ENV_FILE"
  cat > "$ENV_FILE" <<EOF
# Genererad $(date -Iseconds)
POSTGRES_USER=casino
POSTGRES_PASSWORD=$(openssl rand -hex 24)
POSTGRES_DB=casino
JWT_SECRET=$(openssl rand -hex 32)
FRONTEND_URL=https://$DOMAIN

# E-post (valfritt) – ta bort # och fyll i för att skicka riktiga mejl
#SMTP_HOST=
#SMTP_PORT=587
#SMTP_USER=
#SMTP_PASS=
SMTP_FROM=noreply@$ROOTDOMAIN
EOF
  chmod 600 "$ENV_FILE"
}

write_compose() {
  # Tomma SMTP-värden får appen att vägra starta – kommentera bort dem
  sed -i -E 's/^(SMTP_(HOST|USER|PASS)=)$/#\1/' "$ENV_FILE"
  cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  app:
    build: .
    env_file:
      - .env.prod
    environment:
      NODE_ENV: production
      PORT: 3000
      DB_SSL: "false"
      DATABASE_URL: postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@db:5432/\${POSTGRES_DB}?sslmode=disable
      JWT_SECRET: \${JWT_SECRET}
      FRONTEND_URL: \${FRONTEND_URL}
    ports:
      - "127.0.0.1:$PORT:3000"
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

volumes:
  pgdata:
EOF
}

build_and_start() {
  green "==> Bygger och startar (första gången tar några minuter)"
  dc up -d --build
  for _ in $(seq 1 60); do
    if curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
      green "Appen svarar på 127.0.0.1:$PORT"; return
    fi
    sleep 3
  done
  die "Appen svarade inte inom 3 min. Kolla: $0 logs"
}

ensure_subdomain() {
  if uapi --user="$CPUSER" --output=json DomainInfo list_domains | grep -q "\"$DOMAIN\""; then
    green "==> Subdomänen $DOMAIN finns redan"
  else
    green "==> Skapar subdomänen $DOMAIN under $CPUSER"
    uapi --user="$CPUSER" SubDomain addsubdomain \
      domain="$SUB" rootdomain="$ROOTDOMAIN" dir="public_html/$SUB" >/dev/null \
      || die "Kunde inte skapa subdomänen (finns DNS-zonen för $ROOTDOMAIN på servern?)"
  fi
}

ensure_apache_modules() {
  [[ $IS_DEB == 1 ]] && apt-get update -qq
  local mods; mods="$(apache_ctl -M 2>/dev/null || true)"
  for m in proxy_http proxy_wstunnel headers rewrite; do
    if ! grep -q "${m}_module" <<<"$mods"; then
      local p; p="$(ea_pkg "$m")"
      green "==> Installerar $p via EasyApache"
      pkg_install "$p" || die "Kunde inte installera $p (installera via WHM → EasyApache 4)"
    fi
  done
}

write_proxy() {
  green "==> Skriver Apache-proxy för $DOMAIN → 127.0.0.1:$PORT"
  local ssl_dir="$USERDATA/ssl/2_4/$CPUSER/$DOMAIN"
  local std_dir="$USERDATA/std/2_4/$CPUSER/$DOMAIN"
  mkdir -p "$ssl_dir" "$std_dir"

  cat > "$ssl_dir/stakeless.conf" <<EOF
# Stakeless – genererad av install-stakeless-cpanel.sh
ProxyPreserveHost On
ProxyRequests Off
RequestHeader set X-Forwarded-Proto "https"

# Låt AutoSSL:s valideringsfiler serveras av Apache
ProxyPass /.well-known !

# WebSocket (Socket.IO) – live-saldo, crash, poker
RewriteEngine On
RewriteCond %{HTTP:Upgrade} =websocket [NC]
RewriteRule ^/?(.*) ws://127.0.0.1:$PORT/\$1 [P,L]

ProxyPass        / http://127.0.0.1:$PORT/ timeout=3600
ProxyPassReverse / http://127.0.0.1:$PORT/
EOF

  cat > "$std_dir/stakeless.conf" <<EOF
# Stakeless – skicka http till https, men låt AutoSSL-validering gå igenom
RewriteEngine On
RewriteCond %{REQUEST_URI} !^/\.well-known/
RewriteRule ^/?(.*) https://$DOMAIN/\$1 [R=301,L]
EOF

  /scripts/rebuildhttpdconf >/dev/null
  apache_ctl -t 2>/dev/null || { apache_ctl -t; die "Apache-configen är trasig – kolla filerna i $ssl_dir"; }
  /scripts/restartsrv_httpd >/dev/null
}

run_autossl() {
  green "==> Kör AutoSSL för $CPUSER (kan ta en stund)"
  /usr/local/cpanel/bin/autossl_check --user="$CPUSER" >/dev/null 2>&1 \
    || yellow "AutoSSL körde inte klart nu – den kör automatiskt senare. Peka DNS för $DOMAIN hit först."
}

# --------------------------------------------------------------------------- #
cmd_install() {
  preflight
  install_docker
  fetch_code
  write_env
  write_compose
  build_and_start
  ensure_subdomain
  ensure_apache_modules
  write_proxy
  run_autossl
  cat <<EOF

$(green "Klart!")  →  https://$DOMAIN

  1. Registrera dig på sidan
  2. Gör dig till admin:  $0 admin <ditt-användarnamn>

EOF
}

cmd_update() {
  preflight
  fetch_code
  write_compose
  build_and_start
  green "Uppdaterad."
}

cmd_admin() {
  local user="${1:-}"
  [[ "$user" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Användning: $0 admin <namn>"
  local res; res="$(psql_exec -tA -c "UPDATE users SET role='admin' WHERE username='$user' RETURNING username;")"
  [[ -n "$res" ]] && green "$user är nu admin." || die "Ingen användare heter '$user'."
}

cmd_chips() {
  local user="${1:-}" amount="${2:-}"
  [[ "$user" =~ ^[A-Za-z0-9_.-]+$ && "$amount" =~ ^-?[0-9]+$ ]] || die "Användning: $0 chips <namn> <antal>"
  local res; res="$(psql_exec -tA -c "UPDATE users SET balance = GREATEST(balance + $amount, 0) WHERE username='$user' RETURNING balance;")"
  [[ -n "$res" ]] && green "$user har nu $res chips." || die "Ingen användare heter '$user'."
}

LOCK_CONF="$USERDATA/ssl/2_4/$CPUSER/$DOMAIN/00-lock.conf"

reload_apache() {
  /scripts/rebuildhttpdconf >/dev/null
  apache_ctl -t 2>/dev/null || { apache_ctl -t; die "Apache-configen är trasig"; }
  /scripts/restartsrv_httpd >/dev/null
}

# Låset bygger på en hemlig cookie istället för lösenordsruta (Basic Auth),
# eftersom appen själv använder Authorization-headern för sina inloggningar.
cmd_lock() {
  preflight
  local key; key="$(openssl rand -hex 16)"
  mkdir -p "$(dirname "$LOCK_CONF")"
  cat > "$LOCK_CONF" <<EOF
# Tillfälligt lås – ta bort med: $0 unlock
RewriteEngine On

# Besök /__unlock?key=... en gång för att få en cookie som släpper in dig
RewriteCond %{QUERY_STRING} (^|&)key=$key(&|\$)
RewriteRule ^/?__unlock\$ / [R=302,L,CO=stakeless_lock:$key:$DOMAIN:43200:/:secure:httponly]

# Alla andra utan rätt cookie får 403 (AutoSSL-validering släpps igenom)
RewriteCond %{REQUEST_URI} !^/\.well-known/
RewriteCond %{HTTP_COOKIE} !(^|;\s*)stakeless_lock=$key(;|\$)
RewriteRule ^ - [F,L]
EOF
  reload_apache
  green "🔒 $DOMAIN är låst för alla utom dig."
  echo
  echo "  Öppna den här länken en gång i varje webbläsare du vill testa i:"
  echo "    https://$DOMAIN/__unlock?key=$key"
  echo
  echo "  Cookien gäller i 30 dagar. Öppna för alla igen med: $0 unlock"
}

cmd_unlock() {
  preflight
  rm -f "$LOCK_CONF"
  reload_apache
  green "🔓 $DOMAIN är öppen för alla igen."
}

case "${1:-install}" in
  install) cmd_install ;;
  update)  cmd_update ;;
  proxy)   preflight; ensure_apache_modules; write_proxy ;;
  admin)   shift; cmd_admin "$@" ;;
  chips)   shift; cmd_chips "$@" ;;
  logs)    dc logs -f --tail=200 app ;;
  stop)    dc down ;;
  lock)    cmd_lock ;;
  unlock)  cmd_unlock ;;
  *)       die "Okänt kommando: $1 (install | update | proxy | admin | chips | lock | unlock | logs | stop)" ;;
esac
