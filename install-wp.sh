#!/bin/bash
# Installiert eine neue WordPress- oder WooCommerce-Site
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# Lokale Plugin-ZIP robust installieren: Install und Aktivierung in GETRENNTE
# wp-cli-Prozesse. Manche Aktivierungs-Hooks laden WP-Core-Dateien (plugin-install.php,
# class-wp-upgrader.php) per require erneut → "Cannot (re)declare …" im selben Prozess
# wie "install --activate". Der Slug wird aus dem Top-Ordner der ZIP ermittelt (unzip),
# kein fragiles Parsen der wp-cli-Ausgabe. Nutzt globale $SYSTEM_USER / $SITE_PATH.
install_local_zip() {
    local zip="$1" label="${2:-$1}" slug
    [[ -f "$zip" ]] || { warn "ZIP fehlt: ${zip} — ${label} übersprungen"; return 1; }
    # || true: head schließt die Pipe nach der 1. Zeile → unzip (schreibt alle ZIP-
    # Einträge) bekommt SIGPIPE, was unter set -o pipefail als Exit 141 durchschlägt.
    slug=$(unzip -Z1 "$zip" 2>/dev/null | head -1 | cut -d/ -f1) || true
    sudo -u "$SYSTEM_USER" wp plugin install "$zip" --path="$SITE_PATH" --allow-root \
        || { warn "${label}: Install fehlgeschlagen, übersprungen"; return 1; }
    if [[ -n "$slug" ]]; then
        sudo -u "$SYSTEM_USER" wp plugin activate "$slug" --path="$SITE_PATH" --allow-root \
            || warn "${label}: Aktivierung fehlgeschlagen (Slug ${slug}), übersprungen"
    else
        warn "${label}: Slug nicht aus ZIP ermittelbar — nicht aktiviert"
    fi
}

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash install-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

# ── Flags ─────────────────────────────────────────────────────────────────
FORCE_RESUME=false
NON_INTERACTIVE=false
CLI_DOMAIN=""
CLI_TYPE=""
CLI_ADMIN_IP=""
CLI_SHOP_NAME=""
i=0
ARGS=("$@")
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]}" in
        --resume|--force) FORCE_RESUME=true ;;
        --yes|--non-interactive) NON_INTERACTIVE=true ;;
        --domain)         i=$((i+1)); CLI_DOMAIN="${ARGS[$i]}" ;;
        --type)           i=$((i+1)); CLI_TYPE="${ARGS[$i]}" ;;
        --admin-ip)       i=$((i+1)); CLI_ADMIN_IP="${ARGS[$i]}" ;;
        --shop-name)      i=$((i+1)); CLI_SHOP_NAME="${ARGS[$i]}" ;;
        -h|--help)
            cat <<HELP
Usage: install-wp.sh [Optionen]

Interaktiv (alle Eingaben werden abgefragt):
  sudo bash install-wp.sh

Non-Interaktiv (für Automation):
  sudo bash install-wp.sh --domain example.com --type wordpress --yes
  sudo bash install-wp.sh --domain shop.de --type woocommerce --shop-name "Mein Shop" --yes

Optionen:
  --domain <name>         Domain (z.B. meinshop.de)
  --type <wp|woo>         'wordpress' oder 'woocommerce'
  --admin-ip <ip>         WP-Admin-Zugang auf IP beschränken
  --shop-name <name>      Shop-Name (nur bei WooCommerce)
  --yes                   Bestätigungs-Prompts überspringen
  --resume                Reste einer abgebrochenen Installation entfernen
HELP
            exit 0 ;;
    esac
    i=$((i+1))
done

# ── Konfiguration laden ────────────────────────────────────────────────────
source /etc/wp-hosting/config

# clear scheitert ohne TERM (z.B. non-interaktiv über SSH) und würde mit set -e
# das ganze Skript killen → non-fatal machen.
clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site Installer                   ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
info "VM-Typ: ${BOLD}${VM_TYPE}${NC} | DB-Host: ${BOLD}${DB_HOST}${NC}"
echo ""

# ── Eingaben ────────────────────────────────────────────────────────────────
if [[ -n "$CLI_DOMAIN" ]]; then
    DOMAIN="$CLI_DOMAIN"
else
    read -rp "Domain (ohne https://, z.B. meinshop.de): " DOMAIN
fi
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."
[[ ! "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]] && err "Ungültige Domain: ${DOMAIN}"

# Admin-E-Mail nach festem Schema aus der Domain ableiten: admin_dany@<domain>.
# Überschreibt bewusst einen etwaigen Wert aus /etc/wp-hosting/config.
WP_ADMIN_EMAIL="admin_dany@${DOMAIN}"

if [[ -n "$CLI_TYPE" ]]; then
    case "$CLI_TYPE" in
        wp|wordpress)         SITE_TYPE="wordpress" ;;
        woo|woocommerce|wc)   SITE_TYPE="woocommerce" ;;
        *) err "Ungültiger --type: ${CLI_TYPE} (erlaubt: wordpress, woocommerce)" ;;
    esac
else
    echo ""
    echo "Welche Installation?"
    echo "  1) WordPress"
    echo "  2) WooCommerce"
    echo ""
    read -rp "Auswahl [1/2]: " site_choice
    case "$site_choice" in
        1) SITE_TYPE="wordpress" ;;
        2) SITE_TYPE="woocommerce" ;;
        *) err "Ungültige Auswahl." ;;
    esac
fi

# ── Sanity Check für WooCommerce-Type ─────────────────────────────────────
# Woo auf einer Nicht-Woo-VM bekäme den WP-Vhost MIT FastCGI-Cache, aber OHNE
# Cart/Checkout/Account-Bypass → kaputte/cross-customer Shop-Seiten. Deshalb hart ablehnen.
if [[ "$SITE_TYPE" == "woocommerce" && "${VM_TYPE:-}" != "woocommerce" ]]; then
    err "Diese VM ist nicht als WooCommerce-VM eingerichtet (VM_TYPE=${VM_TYPE:-unbekannt}). Erst setup-web.sh mit Option 2 (WooCommerce) ausführen — sonst fehlt der Cart/Checkout-Cache-Bypass."
fi

if [[ -n "$CLI_ADMIN_IP" ]]; then
    ADMIN_IP="$CLI_ADMIN_IP"
elif ! $NON_INTERACTIVE; then
    echo ""
    read -rp "WP-Admin-Zugang auf bestimmte IP beschränken? (leer = kein Limit): " ADMIN_IP
else
    ADMIN_IP=""
fi

# Shop-Name nur bei WooCommerce
WOO_SHOP_NAME=""
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    if [[ -n "$CLI_SHOP_NAME" ]]; then
        WOO_SHOP_NAME="$CLI_SHOP_NAME"
    elif ! $NON_INTERACTIVE; then
        echo ""
        read -rp "Shop-Name für E-Mail-Versand (leer = Domain): " WOO_SHOP_NAME
    fi
    [[ -z "$WOO_SHOP_NAME" ]] && WOO_SHOP_NAME="$DOMAIN"
fi

echo ""
info "Domain:    ${BOLD}${DOMAIN}${NC}"
info "Typ:       ${BOLD}${SITE_TYPE}${NC}"
[[ -n "$ADMIN_IP" ]]       && info "Admin-IP:  ${BOLD}${ADMIN_IP}${NC}"
[[ -n "$WOO_SHOP_NAME" ]]  && info "Shop-Name: ${BOLD}${WOO_SHOP_NAME}${NC}"
echo ""
if ! $NON_INTERACTIVE; then
    read -rp "Installation starten? [j/N]: " confirm
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
fi

# ── Zugangsdaten generieren ────────────────────────────────────────────────
# Kollisionsfreier, deterministischer Identifier: lesbares Präfix + sha256-Hash der Domain.
# (Früher: tr . _ | tr - _  → a-b.com und a.b-com kollidierten; :0:20 kappte lange Domains.)
DOMAIN_SAFE="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-8)"

DB_NAME="wp_${DOMAIN_SAFE}"
# DB-Username max 32 Zeichen (MariaDB-Limit)
DB_USER="wpdb_$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 10 || true)"
DB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32) || true

WP_ADMIN_USER=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 14) || true
WP_ADMIN_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 28) || true

SITE_PATH="/var/www/${DOMAIN}"
SYSTEM_USER="wp_${DOMAIN_SAFE}"   # DOMAIN_SAFE ist bereits längenbegrenzt (≤21) → wp_<21> = ≤24 < 32
PHP_POOL="/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf"
NGINX_VHOST="/etc/nginx/sites-available/${DOMAIN}"

# ── Pre-Flight-Checks ─────────────────────────────────────────────────────
# Frühe Validierung — verhindert dass die Installation mittendrin scheitert
info "Pre-Flight-Check..."

# DNS auflösbar?
if command -v dig &>/dev/null; then
    DNS_RESULT=$(dig +short +time=3 +tries=1 "$DOMAIN" 2>/dev/null | head -1 || true)
    if [[ -z "$DNS_RESULT" ]]; then
        warn "  DNS: ${DOMAIN} ist nicht auflösbar (Cloudflare A-Record fehlt?)"
        $NON_INTERACTIVE || { read -rp "Trotzdem fortfahren? [j/N]: " ans; [[ "$ans" != "j" && "$ans" != "J" ]] && err "Abgebrochen."; }
    else
        log "  DNS: ${DOMAIN} → ${DNS_RESULT}"
    fi
fi

# DB erreichbar?
if ! MYSQL_PWD="$DB_ADMIN_PASS" mysqladmin ping -h "$DB_HOST" -u "$DB_ADMIN_USER" --silent 2>/dev/null; then
    err "  DB-Host ${DB_HOST} nicht erreichbar oder Credentials falsch."
fi
log "  DB: ${DB_HOST} erreichbar"

# Disk-Space (mind. 1 GB frei in /var/www)
FREE_MB=$(df -m /var/www 2>/dev/null | tail -1 | awk '{print $4}')
if [[ -n "$FREE_MB" && "$FREE_MB" -lt 1024 ]]; then
    err "  Disk-Space: nur ${FREE_MB} MB frei in /var/www (mind. 1 GB nötig)"
fi
log "  Disk: ${FREE_MB} MB frei"

# Reverse-Proxy (Caddy) erreichbar? — HTTPS-Port 443 (NPM/Port 81 gibt es nicht mehr)
if [[ -n "${NPM_IP:-}" ]] && [[ "$NPM_IP" != "127.0.0.1" ]]; then
    if timeout 2 bash -c "</dev/tcp/${NPM_IP}/443" 2>/dev/null; then
        log "  Reverse-Proxy: ${NPM_IP}:443 erreichbar"
    else
        warn "  Reverse-Proxy: ${NPM_IP}:443 NICHT erreichbar — Endpunkt via provision-endpoint.sh einrichten"
    fi
fi

# ── Prüfen ob Site bereits existiert ─────────────────────────────────────
if [[ -d "$SITE_PATH" || -f "$NGINX_VHOST" ]]; then
    if $FORCE_RESUME; then
        warn "Reste einer vorherigen Installation gefunden — werden entfernt (--resume)"
        # Dieselbe Cleanup-Logik wie beim Trap, nur ohne Trap-Trigger:
        rm -f "/etc/nginx/sites-enabled/${DOMAIN}" "/etc/nginx/sites-available/${DOMAIN}"
        rm -f "/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf"
        rm -f "/etc/cron.d/wpcron-${DOMAIN_SAFE}"
        SFTP_CHROOT="/var/sftp/wp_${DOMAIN_SAFE:0:20}"
        if mountpoint -q "${SFTP_CHROOT}/site" 2>/dev/null; then umount "${SFTP_CHROOT}/site" || true; fi
        sed -i "\|${SITE_PATH}.*${SFTP_CHROOT}/site|d" /etc/fstab 2>/dev/null || true
        rm -rf "$SFTP_CHROOT" "$SITE_PATH"
        id "wp_${DOMAIN_SAFE:0:20}" &>/dev/null && userdel "wp_${DOMAIN_SAFE:0:20}" 2>/dev/null || true
        getent group "wp_${DOMAIN_SAFE:0:20}" &>/dev/null && groupdel "wp_${DOMAIN_SAFE:0:20}" 2>/dev/null || true
        MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" 2>/dev/null <<SQL || true
DROP DATABASE IF EXISTS \`wp_${DOMAIN_SAFE}\`;
SQL
        rm -f "/etc/wp-hosting/sites/${DOMAIN}.txt"
        systemctl reload nginx 2>/dev/null || true
        systemctl reload php8.3-fpm 2>/dev/null || true
        log "Cleanup abgeschlossen — Installation startet neu"
    else
        [[ -d "$SITE_PATH" ]]   && err "Verzeichnis ${SITE_PATH} existiert bereits. (Tipp: --resume)"
        [[ -f "$NGINX_VHOST" ]] && err "Nginx-Vhost für ${DOMAIN} existiert bereits. (Tipp: --resume)"
    fi
fi

# ── Cleanup-Trap bei Fehler ───────────────────────────────────────────────
# Wird bei set -e automatisch ausgelöst wenn ein Befehl fehlschlägt.
# Hinterlässt keine halb-fertigen Überreste.
_INSTALL_DONE=false
cleanup_on_error() {
    [[ "$_INSTALL_DONE" == "true" ]] && return
    local FAILED_CMD="${BASH_COMMAND:-?}"
    local FAILED_LINE="${BASH_LINENO[0]:-?}"
    echo ""
    echo -e "${RED}[✗]${NC} Installation fehlgeschlagen (Zeile ${FAILED_LINE}: ${FAILED_CMD})"
    echo -e "${RED}[✗]${NC} Räume auf — bereits angelegte Ressourcen werden entfernt..."

    # Logfile mit Aufräum-Aktionen
    CLEANUP_LOG="/var/log/wp-install-cleanup.log"
    echo "[$(date '+%Y-%m-%d %H:%M')] Cleanup für ${DOMAIN:-?} (Zeile ${FAILED_LINE})" >> "$CLEANUP_LOG"

    # Nginx-Vhost entfernen
    rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
    rm -f "/etc/nginx/sites-available/${DOMAIN}"

    # PHP-FPM Pool entfernen
    rm -f "/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf"

    # WP-Cron entfernen
    rm -f "/etc/cron.d/wpcron-${DOMAIN_SAFE}"

    # SFTP Chroot unmounten und entfernen
    SFTP_CHROOT="/var/sftp/${SYSTEM_USER}"
    if mountpoint -q "${SFTP_CHROOT}/site" 2>/dev/null; then
        umount "${SFTP_CHROOT}/site" 2>/dev/null || true
    fi
    sed -i "\|${SITE_PATH}.*${SFTP_CHROOT}/site|d" /etc/fstab 2>/dev/null || true
    rm -rf "$SFTP_CHROOT"

    # Filebrowser User entfernen. Auch hier gilt: der laufende Dienst haelt die Bolt-DB
    # exklusiv, ein CLI-Zugriff liefe sonst in "Error: timeout" und der User bliebe als
    # Leiche zurueck. Dienst daher kurz stoppen (best effort, Rollback-Pfad).
    FB_DB="/etc/filebrowser/database.db"
    FB_USER="${DOMAIN_SAFE:0:32}"
    if [[ -f "$FB_DB" ]] && command -v filebrowser &>/dev/null; then
        _fb_was_active=false
        if systemctl is-active --quiet filebrowser 2>/dev/null; then _fb_was_active=true; fi
        $_fb_was_active && { systemctl stop filebrowser 2>/dev/null || true; }
        filebrowser users rm "$FB_USER" --database "$FB_DB" >/dev/null 2>&1 || true
        $_fb_was_active && { systemctl start filebrowser 2>/dev/null || true; }
    fi

    # Site-Verzeichnis entfernen
    rm -rf "$SITE_PATH"

    # Systemuser + gleichnamige Gruppe entfernen (Gruppe bleibt sonst verwaist zurück,
    # weil www-data noch Mitglied ist → blockiert useradd beim nächsten Lauf).
    id "$SYSTEM_USER" &>/dev/null && userdel "$SYSTEM_USER" 2>/dev/null || true
    getent group "$SYSTEM_USER" &>/dev/null && groupdel "$SYSTEM_USER" 2>/dev/null || true

    # Datenbank und User entfernen
    WEB_VM_IP=$(hostname -I | awk '{print $1}')
    MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" 2>/dev/null <<SQL || true
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'${WEB_VM_IP}';
SQL

    # Services neu laden
    systemctl reload nginx 2>/dev/null || true
    systemctl reload php8.3-fpm 2>/dev/null || true

    echo -e "${YELLOW}[!]${NC} Cleanup abgeschlossen. Ursache prüfen und Installation erneut starten."
}
trap cleanup_on_error ERR

# ── Systemuser anlegen ────────────────────────────────────────────────────
if ! id "$SYSTEM_USER" &>/dev/null; then
    # Die gleichnamige Gruppe kann aus einem früheren (abgebrochenen) Lauf verwaist
    # übrig sein — userdel entfernt sie nicht, wenn www-data noch Mitglied ist. groupadd -f
    # toleriert eine vorhandene Gruppe; useradd -g nutzt sie explizit, statt eine neue
    # anzulegen (sonst "useradd: group already exists", Exit-Code 9 → Abbruch bei --resume).
    groupadd -f "$SYSTEM_USER"
    useradd -r -s /sbin/nologin -d "$SITE_PATH" -g "$SYSTEM_USER" "$SYSTEM_USER"
fi
# Mandantentrennung: jede Site hat eine eigene Gruppe (= Username). Der PHP-FPM-Worker
# läuft als ${SYSTEM_USER}:${SYSTEM_USER} → PHP-Prozesse anderer Sites (fremde Gruppe)
# können die Dateien dieser Site nicht lesen. Damit nginx (www-data) die statischen
# Dateien trotzdem ausliefern kann, kommt www-data in die Site-Gruppe (nginx-RESTART
# unten übernimmt die neue Gruppenmitgliedschaft).
usermod -aG "$SYSTEM_USER" www-data
log "Systemuser: ${SYSTEM_USER}"

# ── Site-Verzeichnis ──────────────────────────────────────────────────────
mkdir -p "${SITE_PATH}"
chown "${SYSTEM_USER}:${SYSTEM_USER}" "${SITE_PATH}"
chmod 750 "${SITE_PATH}"
log "Verzeichnis: ${SITE_PATH}"

# ── PHP-FPM Pool ──────────────────────────────────────────────────────────
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))

if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    # WooCommerce: static process manager für konstante Performance
    WORKER_MEM=120
    MAX_CHILDREN=$((TOTAL_RAM_MB / 4 / WORKER_MEM))
    [[ $MAX_CHILDREN -lt 4 ]] && MAX_CHILDREN=4
    [[ $MAX_CHILDREN -gt 20 ]] && MAX_CHILDREN=20

    cat > "$PHP_POOL" <<EOF
[${DOMAIN}]
user  = ${SYSTEM_USER}
group = ${SYSTEM_USER}

listen = /run/php/php8.3-fpm-${DOMAIN}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

; static: Prozesse bleiben immer aktiv — besser für WooCommerce unter Last
pm               = static
pm.max_children  = ${MAX_CHILDREN}
pm.max_requests  = 500

; Status-Endpoint für Pool-Monitoring (über nginx /fpm-status, Basic-Auth)
pm.status_path   = /fpm-status
ping.path        = /fpm-ping
ping.response    = pong

php_admin_value[memory_limit]         = 512M
php_admin_value[upload_max_filesize]  = 128M
php_admin_value[post_max_size]        = 128M
php_admin_value[max_execution_time]   = 300
php_admin_value[max_input_time]       = 300
php_admin_value[max_input_vars]       = 10000
php_admin_value[error_log]            = /var/log/php/${DOMAIN}.error.log
php_admin_flag[log_errors]            = on

slowlog                               = /var/log/php/${DOMAIN}.slow.log
request_slowlog_timeout               = 5s
EOF
else
    # WordPress: dynamic — spart RAM bei wenig Traffic
    WORKER_MEM=80
    MAX_CHILDREN=$((TOTAL_RAM_MB / 4 / WORKER_MEM))
    [[ $MAX_CHILDREN -lt 3 ]] && MAX_CHILDREN=3
    [[ $MAX_CHILDREN -gt 12 ]] && MAX_CHILDREN=12
    START=$((MAX_CHILDREN / 3))
    [[ $START -lt 1 ]] && START=1

    cat > "$PHP_POOL" <<EOF
[${DOMAIN}]
user  = ${SYSTEM_USER}
group = ${SYSTEM_USER}

listen = /run/php/php8.3-fpm-${DOMAIN}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

pm                   = dynamic
pm.max_children      = ${MAX_CHILDREN}
pm.start_servers     = ${START}
pm.min_spare_servers = 1
pm.max_spare_servers = $((START + 1))
pm.max_requests      = 500

; Status-Endpoint für Pool-Monitoring (über nginx /fpm-status, Basic-Auth)
pm.status_path       = /fpm-status
ping.path            = /fpm-ping
ping.response        = pong

php_admin_value[memory_limit]         = 256M
php_admin_value[upload_max_filesize]  = 64M
php_admin_value[post_max_size]        = 64M
php_admin_value[max_execution_time]   = 60
php_admin_value[max_input_time]       = 60
php_admin_value[max_input_vars]       = 5000
php_admin_value[error_log]            = /var/log/php/${DOMAIN}.error.log
php_admin_flag[log_errors]            = on

slowlog                               = /var/log/php/${DOMAIN}.slow.log
request_slowlog_timeout               = 5s
EOF
fi

mkdir -p /var/log/php
log "PHP-FPM Pool konfiguriert (${SITE_TYPE}, ${MAX_CHILDREN} Worker)"

# ── Nginx Vhost ───────────────────────────────────────────────────────────
SOCK="/run/php/php8.3-fpm-${DOMAIN}.sock"

if [[ "$SITE_TYPE" == "woocommerce" && "$VM_TYPE" == "woocommerce" ]]; then
    # WooCommerce: FastCGI-Cache mit smarten Bypass-Regeln
    cat > "$NGINX_VHOST" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_PATH};
    index index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log main;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";

    # Cache-Bypass: Warenkörbe, Login, Admin, POST-Requests
    set \$skip_cache 0;
    if (\$request_method = POST)                                          { set \$skip_cache 1; }
    if (\$query_string != "")                                             { set \$skip_cache 1; }
    if (\$request_uri ~* "/cart|/checkout|/my-account|/wc-api|/wp-admin|\?wc-ajax=|/feed") {
        set \$skip_cache 1;
    }
    if (\$http_cookie ~* "wordpress_logged_in|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session") {
        set \$skip_cache 1;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_cache            WPCACHE;
        fastcgi_cache_valid      200 301 302 1h;
        fastcgi_cache_use_stale  error timeout updating http_500;
        fastcgi_cache_lock       on;
        fastcgi_cache_bypass     \$skip_cache;
        fastcgi_no_cache         \$skip_cache;
        fastcgi_cache_key        "\$scheme\$request_method\$host\$request_uri";
        add_header               X-FastCGI-Cache \$upstream_cache_status;
    }

    location ~* \.(jpg|jpeg|png|gif)\$ {
        add_header Vary Accept;
        try_files \$uri\$webp_suffix \$uri =404;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~* \.(ico|css|js|pdf|txt|woff|woff2|ttf|svg|webp|avif)\$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~ /\.(ht|git|env)            { deny all; }
    location ~ /(wp-config\.php|readme\.html|license\.txt|wp-config-sample\.php)\$ { deny all; }
    location ~* /(?:uploads|files)/.*\.php\$ { deny all; }
    location = /xmlrpc.php                 { deny all; }

    # OPcache-Status (Basic-Auth, gleiches Passwort wie phpMyAdmin)
    location = /opcache-status {
        auth_basic           "Restricted";
        auth_basic_user_file /etc/nginx/.pma_htpasswd;
        include              snippets/fastcgi-php.conf;
        fastcgi_pass         unix:${SOCK};
        fastcgi_param        SCRIPT_FILENAME /var/lib/wp-hosting/opcache-status.php;
        include              fastcgi_params;
    }

    # PHP-FPM Pool-Status (Basic-Auth, gleiches Passwort wie phpMyAdmin)
    location = /fpm-status {
        auth_basic           "Restricted";
        auth_basic_user_file /etc/nginx/.pma_htpasswd;
        fastcgi_pass         unix:${SOCK};
        fastcgi_param        SCRIPT_FILENAME \$fastcgi_script_name;
        include              fastcgi_params;
    }
    location = /fpm-ping {
        access_log           off;
        fastcgi_pass         unix:${SOCK};
        fastcgi_param        SCRIPT_FILENAME \$fastcgi_script_name;
        include              fastcgi_params;
    }

$(if [[ -n "$ADMIN_IP" ]]; then
cat <<IPEOF
    location /wp-admin/ {
        allow ${ADMIN_IP};
        deny all;
    }
    location = /wp-login.php {
        allow ${ADMIN_IP};
        deny all;
        limit_req zone=login burst=3 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        include fastcgi_params;
    }
IPEOF
else
cat <<NOIPEOF
    location = /wp-login.php { limit_req zone=login burst=3 nodelay; include snippets/fastcgi-php.conf; fastcgi_pass unix:${SOCK}; include fastcgi_params; }
NOIPEOF
fi)
}
EOF
else
    # WordPress: FastCGI-Cache (ohne WooCommerce-spezifische Bypass-Regeln)
    cat > "$NGINX_VHOST" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_PATH};
    index index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log main;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";

    # Cache-Bypass: Admin, Login, eingeloggte User, POST-Requests
    set \$skip_cache 0;
    if (\$request_method = POST)                              { set \$skip_cache 1; }
    if (\$query_string != "")                                 { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin|/wp-login\.php|/feed")   { set \$skip_cache 1; }
    if (\$http_cookie ~* "wordpress_logged_in")               { set \$skip_cache 1; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_cache            WPCACHE;
        fastcgi_cache_valid      200 301 302 1h;
        fastcgi_cache_use_stale  error timeout updating http_500;
        fastcgi_cache_lock       on;
        fastcgi_cache_bypass     \$skip_cache;
        fastcgi_no_cache         \$skip_cache;
        fastcgi_cache_key        "\$scheme\$request_method\$host\$request_uri";
        add_header               X-FastCGI-Cache \$upstream_cache_status;
    }

    location ~* \.(jpg|jpeg|png|gif)\$ {
        add_header Vary Accept;
        try_files \$uri\$webp_suffix \$uri =404;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~* \.(ico|css|js|pdf|txt|woff|woff2|ttf|svg|webp|avif)\$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~ /\.(ht|git|env)            { deny all; }
    location ~ /(wp-config\.php|readme\.html|license\.txt|wp-config-sample\.php)\$ { deny all; }
    location ~* /(?:uploads|files)/.*\.php\$ { deny all; }
    location = /xmlrpc.php                 { deny all; }

    # OPcache-Status (Basic-Auth, gleiches Passwort wie phpMyAdmin)
    location = /opcache-status {
        auth_basic           "Restricted";
        auth_basic_user_file /etc/nginx/.pma_htpasswd;
        include              snippets/fastcgi-php.conf;
        fastcgi_pass         unix:${SOCK};
        fastcgi_param        SCRIPT_FILENAME /var/lib/wp-hosting/opcache-status.php;
        include              fastcgi_params;
    }

    # PHP-FPM Pool-Status (Basic-Auth, gleiches Passwort wie phpMyAdmin)
    location = /fpm-status {
        auth_basic           "Restricted";
        auth_basic_user_file /etc/nginx/.pma_htpasswd;
        fastcgi_pass         unix:${SOCK};
        fastcgi_param        SCRIPT_FILENAME \$fastcgi_script_name;
        include              fastcgi_params;
    }
    location = /fpm-ping {
        access_log           off;
        fastcgi_pass         unix:${SOCK};
        fastcgi_param        SCRIPT_FILENAME \$fastcgi_script_name;
        include              fastcgi_params;
    }

$(if [[ -n "$ADMIN_IP" ]]; then
cat <<IPEOF
    location /wp-admin/ {
        allow ${ADMIN_IP};
        deny all;
    }
    location = /wp-login.php {
        allow ${ADMIN_IP};
        deny all;
        limit_req zone=login burst=3 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        include fastcgi_params;
    }
IPEOF
else
cat <<NOIPEOF
    location = /wp-login.php { limit_req zone=login burst=3 nodelay; include snippets/fastcgi-php.conf; fastcgi_pass unix:${SOCK}; include fastcgi_params; }
NOIPEOF
fi)
}
EOF
fi

# Rate-Limit Zone für wp-login (einmalig in nginx.conf wenn noch nicht vorhanden)
if ! grep -q "zone=login" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=login:10m rate=1r\/s;' /etc/nginx/nginx.conf
fi

ln -sf "$NGINX_VHOST" "/etc/nginx/sites-enabled/${DOMAIN}"
log "Nginx Vhost erstellt"

# ── Datenbank anlegen ─────────────────────────────────────────────────────
MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'$(hostname -I | awk '{print $1}')' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER ON \`${DB_NAME}\`.* TO '${DB_USER}'@'$(hostname -I | awk '{print $1}')';
FLUSH PRIVILEGES;
SQL
log "Datenbank angelegt: ${DB_NAME}"

# ── WordPress installieren ────────────────────────────────────────────────
# wp-cli 'rewrite structure/flush' nutzt intern runcommand(launch=true) und spawnt
# einen Subprozess via proc_open, der das aktuelle Arbeitsverzeichnis erbt. Läuft das
# Script aus /home/ubuntu (Standard bei 'sudo bash install-wp.sh'), kann der nologin-
# Systemuser dieses cwd nicht betreten → posix_spawn 'Permission denied' → Fatal.
# Daher ins Site-Verzeichnis wechseln, das dem Systemuser gehört.
cd "$SITE_PATH"
info "WordPress wird heruntergeladen..."
sudo -u "$SYSTEM_USER" wp core download --path="$SITE_PATH" --locale=en_US --allow-root

# DB-Passwort per stdin (--prompt=dbpass), nicht als --dbpass in der argv (Prozessliste).
# stdout nach /dev/null: wp-cli druckt bei --prompt die zusammengesetzte Kommandozeile
# inklusive Passwort. Fehler kommen weiter über stderr.
printf '%s\n' "$DB_PASS" | sudo -u "$SYSTEM_USER" wp config create \
    --path="$SITE_PATH" \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --prompt=dbpass --quiet \
    --dbhost="$DB_HOST" \
    --dbcharset="utf8mb4" \
    --dbcollate="utf8mb4_unicode_ci" \
    --extra-php="define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DISABLE_BANNERS', true);
define('WP_CACHE_KEY_SALT', '${DOMAIN}:');
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 7);
define('DISALLOW_FILE_EDIT', true);
define('FORCE_SSL_ADMIN', true);
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', false);
define('WP_DEBUG_DISPLAY', false);
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
define('AUTOSAVE_INTERVAL', 120);
define('WP_CACHE', true);
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { \$_SERVER['HTTPS'] = 'on'; }" \
    --allow-root >/dev/null

# Lizenzschlüssel nicht über --extra-php (argv → sudo-Log), sondern per Bash vor die
# "That's all"-Zeile der wp-config.php schreiben (stdin ist schon durch --prompt belegt).
if [[ -n "${SEOPRESS_KEY:-}" ]]; then
    _cfg="${SITE_PATH}/wp-config.php"; _tmp=$(mktemp "${SITE_PATH}/.wp-config.XXXXXX"); _n=0
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        if [[ "$_l" == "/* That's all, stop editing"* ]]; then
            printf "define( 'SEOPRESS_LICENSE_KEY', '%s' );\n" "$SEOPRESS_KEY"; _n=$((_n + 1))
        fi
        printf '%s\n' "$_l"
    done < "$_cfg" > "$_tmp"
    [[ $_n -eq 1 ]] || { rm -f "$_tmp"; err "wp-config.php: Einfügemarke ${_n}x gefunden (erwartet 1)"; }
    chown --reference="$_cfg" "$_tmp"; mv "$_tmp" "$_cfg"
fi

# Admin-Passwort ebenfalls per stdin (--prompt=admin_password), stdout aus demselben Grund weg.
printf '%s\n' "$WP_ADMIN_PASS" | sudo -u "$SYSTEM_USER" wp core install \
    --path="$SITE_PATH" \
    --url="https://${DOMAIN}" \
    --title="${DOMAIN}" \
    --admin_user="$WP_ADMIN_USER" \
    --prompt=admin_password --quiet \
    --admin_email="$WP_ADMIN_EMAIL" \
    --skip-email \
    --allow-root >/dev/null
log "WordPress installiert"

# ── WordPress-Einstellungen ────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp option update timezone_string "Europe/Berlin"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update date_format "Y-m-d"              --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update time_format "H:i"                --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update WPLANG ""                        --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp rewrite structure "/%category%/%postname%/"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp rewrite flush                                  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp user update "$WP_ADMIN_USER" \
    --first_name="Danijel" \
    --last_name="Janzin" \
    --nickname="Dany" \
    --display_name="Dany" \
    --path="$SITE_PATH" --allow-root

# Kommentar-Einstellungen
sudo -u "$SYSTEM_USER" wp option update require_name_email          "1"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update comment_moderation          "0"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update comment_previously_approved "1"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update close_comments_for_old_posts "1"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update close_comments_days_old     "90"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update default_comment_status      "open" --path="$SITE_PATH" --allow-root

# Media-Größen
sudo -u "$SYSTEM_USER" wp option update thumbnail_size_w "300"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update thumbnail_size_h "300"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update thumbnail_crop   "1"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update medium_size_w    "768"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update medium_size_h    "0"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update large_size_w     "1200" --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update large_size_h     "0"    --path="$SITE_PATH" --allow-root

log "Einstellungen gesetzt (Timezone: Europe/Berlin, Sprache: English, Permalinks: /%category%/%postname%/)"

# ── Theme: Blocksy + Child ────────────────────────────────────────────────
# Blocksy als Standard-Theme (FSE-fähig, performant). Child wird aktiviert,
# damit Anpassungen Updates des Parent-Themes überleben.
THEMES_DIR="/etc/wp-hosting/themes"
if [[ -f "${THEMES_DIR}/blocksy.zip" ]]; then
    sudo -u "$SYSTEM_USER" wp theme install "${THEMES_DIR}/blocksy.zip" \
        --path="$SITE_PATH" --allow-root 2>/dev/null || true

    if [[ -f "${THEMES_DIR}/blocksy-child.zip" ]]; then
        sudo -u "$SYSTEM_USER" wp theme install "${THEMES_DIR}/blocksy-child.zip" --activate \
            --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
        log "Blocksy + Child Theme installiert (Child aktiv → Anpassungen update-sicher)"
    else
        sudo -u "$SYSTEM_USER" wp theme activate blocksy --path="$SITE_PATH" --allow-root
        log "Blocksy Theme installiert und aktiviert"
    fi
else
    warn "Blocksy nicht gefunden (${THEMES_DIR}/blocksy.zip) — sync-plugins.sh --themes ausführen"
fi

# ── Redis Object Cache ─────────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install redis-cache --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
sudo -u "$SYSTEM_USER" wp redis enable --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Redis Object Cache aktiviert"

# ── FluentSMTP (E-Mail-Versand) ───────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install fluent-smtp --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
log "FluentSMTP installiert (→ SMTP-Zugangsdaten in WP-Admin → FluentSMTP eintragen)"

# ── WebP Bildoptimierung ──────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install webp-converter-for-media --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
log "Converter for Media installiert (WebP-Konvertierung bei Upload)"

# ── Two Factor (2FA für WP-Admin) ────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install two-factor --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
log "Two Factor installiert (→ Profil → Two Factor Options → QR-Code scannen)"

# ── SEOpress ──────────────────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install wp-seopress --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
SEOPRESS_PRO_ZIP="/etc/wp-hosting/plugins/seopress-pro.zip"
if [[ -f "$SEOPRESS_PRO_ZIP" ]]; then
    sudo -u "$SYSTEM_USER" wp plugin install "$SEOPRESS_PRO_ZIP" --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
    log "SEOpress + SEOpress Pro installiert"
else
    log "SEOpress installiert (Pro ZIP nicht gefunden → /etc/wp-hosting/plugins/seopress-pro.zip)"
fi

# ── FAZ Cookie Manager (DSGVO Cookie Consent) ────────────────────────────
FAZ_URL=$(curl -s https://api.github.com/repos/fabiodalez-dev/FAZ-Cookie-Manager/releases/latest \
    | grep "browser_download_url.*full\.zip" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/' || true)
if [[ -n "$FAZ_URL" ]]; then
    sudo -u "$SYSTEM_USER" wp plugin install "$FAZ_URL" --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
    log "FAZ Cookie Manager installiert (→ Setup-Wizard in WP-Admin ausführen)"
else
    warn "FAZ Cookie Manager: GitHub-URL nicht gefunden — manuell installieren"
fi

# ── Antispam Bee (Kommentar-Spam) ─────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install antispam-bee --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
sudo -u "$SYSTEM_USER" wp option update antispam_bee \
    '{"regexp_check":1,"gravatar_check":1,"time_check":1,"country_code":"","flag_spam":0,"delete_spam":1,"spam_delete_days":7,"generate_css":0,"already_commented":0,"safe_number_chars":0,"no_comment_reason":0}' \
    --format=json --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Antispam Bee aktiviert"

# ── Cloudflare Turnstile (Fake-Anmeldungen / Bot-Schutz) ──────────────────
sudo -u "$SYSTEM_USER" wp plugin install simple-cloudflare-turnstile --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
log "Cloudflare Turnstile installiert (→ Site Key + Secret Key in WP-Admin eintragen)"

# ── Nginx Helper (FastCGI Cache-Invalidierung — für alle Site-Typen) ───────
sudo -u "$SYSTEM_USER" wp plugin install nginx-helper --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
sudo -u "$SYSTEM_USER" wp option update rt_wp_nginx_helper_options \
    '{"enable_purge":"1","cache_method":"enable_fastcgi","purge_method":"get_request","enable_map":null,"enable_log":null,"log_level":"INFO","log_filesize":"5","enable_stamp":null,"purge_homepage_on_edit":"1","purge_homepage_on_del":"1","purge_archive_on_edit":"1","purge_archive_on_del":"1","purge_archive_on_new_comment":"1","purge_archive_on_deleted_comment":"1","purge_page_on_mod":"1","purge_page_on_new_comment":"1","purge_page_on_deleted_comment":"1","nginx_server_ip":"127.0.0.1","purge_url":"","redis_hostname":"127.0.0.1","redis_port":"6379","redis_prefix":"nginx-cache:"}' \
    --format=json --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Nginx Helper (FastCGI Cache-Invalidierung) aktiviert"

# ── Fluent Forms (Formulare — Free-Basis + Pro-Add-on) ─────────────────────
# Pro ist ein Add-on und benötigt die Free-Basis aus dem WP-Repo darunter.
sudo -u "$SYSTEM_USER" wp plugin install fluentform --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
FLUENTFORM_PRO_ZIP="/etc/wp-hosting/plugins/fluentformpro.zip"
if [[ -f "$FLUENTFORM_PRO_ZIP" ]]; then
    sudo -u "$SYSTEM_USER" wp plugin install "$FLUENTFORM_PRO_ZIP" --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"
    log "Fluent Forms + Fluent Forms Pro installiert"

    # Lizenz hinterlegen UND aktivieren. Das blosse Setzen der Option genuegt NICHT —
    # die Aktivierung ist ein Remote-Call (EDD activate_license) an wpmanageninja.
    # tryActivateLicense() ist genau der Handler, den auch das Admin-Formular ausloest.
    # Der Key wird per eval-file uebergeben, damit er nicht in der Prozessliste steht.
    # Hinweis: FluentFormAddOnChecker ist eine plugin-interne Klasse, kein offizielles
    # API — schlaegt der Aufruf fehl (z.B. nach Umbenennung), gibt es nur eine Warnung.
    if [[ -n "${FLUENTFORM_KEY:-}" ]]; then
        FF_ACT_PHP=$(mktemp /tmp/ffact.XXXXXX.php)
        chmod 600 "$FF_ACT_PHP"
        cat > "$FF_ACT_PHP" <<'FFEOF'
<?php
$key = trim(getenv('FF_LICENSE_KEY'));
if (!$key) { echo "no-key\n"; return; }
update_option('_ff_fluentform_pro_license_key', $key);
if (!class_exists('FluentFormAddOnChecker')) { echo "no-class\n"; return; }
$checker = FluentFormAddOnChecker::getInstance();
if (!is_object($checker) || !method_exists($checker, 'tryActivateLicense')) { echo "no-method\n"; return; }
$res = $checker->tryActivateLicense($key);
echo (is_array($res) && isset($res['status'])) ? $res['status'] . "\n" : "unknown\n";
FFEOF
        # Kein chown: die Datei enthaelt keinen Schluessel (der kommt per Env), sie muss
        # nur vom Site-User lesbar sein. Ein Eigentuemerwechsel wuerde das spaetere rm
        # in /tmp (Sticky Bit) unnoetig erschweren.
        chmod 644 "$FF_ACT_PHP"
        FF_STATUS=$(FF_LICENSE_KEY="$FLUENTFORM_KEY" sudo -u "$SYSTEM_USER" --preserve-env=FF_LICENSE_KEY \
            wp eval-file "$FF_ACT_PHP" --path="$SITE_PATH" --allow-root 2>/dev/null | tr -d '\r' | tail -1)
        rm -f "$FF_ACT_PHP"
        if [[ "$FF_STATUS" == "valid" ]]; then
            log "Fluent Forms Pro Lizenz aktiviert"
        else
            warn "Fluent Forms Pro Lizenz NICHT aktiviert (Status: ${FF_STATUS:-keine Antwort}) — im wp-admin nachholen"
        fi
    fi
else
    log "Fluent Forms (Free) installiert — Pro-ZIP nicht gefunden (→ /etc/wp-hosting/plugins/fluentformpro.zip)"
fi

# ── WooCommerce ────────────────────────────────────────────────────────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    info "WooCommerce wird installiert..."
    sudo -u "$SYSTEM_USER" wp plugin install woocommerce --activate --path="$SITE_PATH" --allow-root || warn "Install-Schritt fehlgeschlagen, uebersprungen"

    # Deutsche Sprachdateien
    sudo -u "$SYSTEM_USER" wp language plugin install woocommerce en_US --path="$SITE_PATH" --allow-root 2>/dev/null || true
    log "WooCommerce installiert"
fi

# ── Blocksy Companion Pro (Theme-Erweiterung) ─────────────────────────────
PLUGINS_DIR="/etc/wp-hosting/plugins"
if [[ -f "${PLUGINS_DIR}/blocksy-companion-pro.zip" ]]; then
    install_local_zip "${PLUGINS_DIR}/blocksy-companion-pro.zip" "Blocksy Companion Pro"
    log "Blocksy Companion Pro installiert (Theme-Builder, Header/Footer, Custom Post Types)"
fi

# ── TranslatePress (Mehrsprachigkeit) — Free-Basis + Business-Addon ────────
# Beide ZIPs kommen aus dem Bucket (Dany laedt dort die aktuellen Staende hoch);
# das Business-Addon laeuft nur mit aktiver Free-Basis, daher diese Reihenfolge.
if [[ -f "${PLUGINS_DIR}/translatepress-free.zip" ]]; then
    install_local_zip "${PLUGINS_DIR}/translatepress-free.zip" "TranslatePress"
    log "TranslatePress (Free-Basis) installiert"
    if [[ -f "${PLUGINS_DIR}/translatepress-business.zip" ]]; then
        install_local_zip "${PLUGINS_DIR}/translatepress-business.zip" "TranslatePress Business"
        log "TranslatePress Business installiert (Mehrsprachigkeits-Addon)"
    fi
fi

# ── Site-Type-spezifische Pro-Plugins ─────────────────────────────────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    # WowInvoice — WooCommerce PDF-Rechnungen + Packing Slips
    # Premium-only (kein Free auf wp.org) → vollständiges Plugin direkt aus Bucket-ZIP
    if [[ -f "${PLUGINS_DIR}/wowinvoice-pro.zip" ]]; then
        install_local_zip "${PLUGINS_DIR}/wowinvoice-pro.zip" "WowInvoice"
        log "WowInvoice installiert (PDF-Rechnungen / Packing Slips)"
    else
        warn "WowInvoice ZIP fehlt: ${PLUGINS_DIR}/wowinvoice-pro.zip — sync-plugins.sh ausführen"
    fi

    # FunnelKit Automations — E-Mail-Marketing (Warenkorbabbruch, Broadcasts, Sequenzen)
    # Free-Basis aus WP-Repo + Pro-Add-on aus Bucket
    if sudo -u "$SYSTEM_USER" wp plugin install wp-marketing-automations --activate --path="$SITE_PATH" --allow-root 2>/dev/null; then
        log "FunnelKit Automations (Free-Basis) installiert"
    else
        warn "FunnelKit Automations Free fehlgeschlagen (Slug prüfen: wp-marketing-automations)"
    fi
    if [[ -f "${PLUGINS_DIR}/funnelkit-automations-pro.zip" ]]; then
        # NUR installieren, NICHT aktivieren: Die Pro-ZIP im Bucket kann mit der aktuellen
        # FunnelKit-Free-Basis (wp.org) inkompatibel sein und wirft dann bei Aktivierung
        # "Class BWFAN_API_Loader not found" bei JEDEM WP-Load → vergiftet alle folgenden
        # wp-cli-Aufrufe (Payment-Gateways etc. schlagen fehl, Lauf bricht ab). Aktivierung
        # daher manuell im Dashboard, sobald eine zur Free-Version passende Pro-ZIP vorliegt.
        sudo -u "$SYSTEM_USER" wp plugin install "${PLUGINS_DIR}/funnelkit-automations-pro.zip" \
            --path="$SITE_PATH" --allow-root || warn "FunnelKit Pro: Install fehlgeschlagen, übersprungen"
        warn "FunnelKit Automations Pro installiert, aber NICHT aktiviert — Free/Pro-Versionskompatibilität prüfen, dann im Dashboard aktivieren"
    fi

    # Payment Gateways — nur Plugin-Install + Aktivierung; API-Keys je Shop manuell
    info "Payment Gateways werden installiert (API-Keys je Shop manuell konfigurieren)..."
    for PG_SLUG in \
        mollie-payments-for-woocommerce \
        woocommerce-paypal-payments \
        woocommerce-gateway-stripe \
        woocommerce-gateway-amazon-payments-advanced; do
        if sudo -u "$SYSTEM_USER" wp plugin install "$PG_SLUG" --activate --path="$SITE_PATH" --allow-root 2>/dev/null; then
            log "Payment Gateway: ${PG_SLUG}"
        else
            warn "Payment Gateway ${PG_SLUG} fehlgeschlagen (Slug prüfen / WP-Repo erreichbar?)"
        fi
    done

    # ── Produktfeeds (Lean-Architektur: PFM für ALLE Feeds, PMW für alle Pixel) ──
    # Product Feed Manager (Free): erzeugt JEDEN Katalog/Feed — Google (Content-API-
    #   Auto-Sync), Meta, TikTok, Pinterest, Bing Shopping, Idealo/Preisvergleiche.
    #   Free deckt 24h-Schedule, Custom Fields, Varianten als eigene Zeilen ab.
    #   200-Produkte/Feed-Limit → Pro-Lizenz MANUELL auf Shop mit >200 Produkten
    #   aktivieren (kein Auto-Install, da nur 1-Site-Lizenz).
    # KEINE offiziellen Channel-Plugins (Google/Meta/TikTok for WooCommerce) und KEIN
    #   Pinterest-Plugin (buggy) — PMW + PFM decken Pixel + Feeds vollständig ab.
    info "Product Feed Manager wird installiert (Feed-Konfig je Shop manuell)..."
    if sudo -u "$SYSTEM_USER" wp plugin install best-woocommerce-feed --activate --path="$SITE_PATH" --allow-root 2>/dev/null; then
        log "Product Feed Manager (Free) installiert"
    else
        warn "Product Feed Manager fehlgeschlagen (Slug: best-woocommerce-feed)"
    fi

    # ── Pixel Manager (PMW): EIN Pixel-Tool für alle Ad-Plattformen ──────────
    # Free = Google Ads + GA4 + Meta. Pro (Bucket-ZIP) = TikTok, Pinterest,
    #   Microsoft/Bing, Snapchat … + Server-Side CAPI. Ersetzt Google Tag Manager.
    #   Consent-Gating je Shop über FAZ Cookie Manager (Consent Mode v2).
    #   Pixel-IDs/CAPI je Shop manuell in der GUI. GA4-Measurement-ID setzt das
    #   Provisioning (provision-endpoint.sh, ensure_ga4) — hier nichts eintragen.
    if sudo -u "$SYSTEM_USER" wp plugin install woocommerce-google-adwords-conversion-tracking-tag --activate --path="$SITE_PATH" --allow-root 2>/dev/null; then
        log "Pixel Manager (Free-Basis) installiert"
    else
        warn "Pixel Manager fehlgeschlagen (Slug: woocommerce-google-adwords-conversion-tracking-tag)"
    fi
    if [[ -f "${PLUGINS_DIR}/pixel-manager-pro.zip" ]]; then
        install_local_zip "${PLUGINS_DIR}/pixel-manager-pro.zip" "Pixel Manager PRO"
        log "Pixel Manager PRO installiert (TikTok/Pinterest/Bing + Server-Side CAPI)"
    else
        warn "Pixel Manager PRO ZIP fehlt: ${PLUGINS_DIR}/pixel-manager-pro.zip — für TikTok/Pinterest/Bing + CAPI nötig"
    fi
fi


# ── Bloat entfernen ───────────────────────────────────────────────────────
# Überflüssige Plugins
sudo -u "$SYSTEM_USER" wp plugin delete hello akismet \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true

# Default-Themes löschen — Blocksy ist aktiv, twentytwentyfive bleibt als Notfall-Fallback
# (wp theme delete weigert sich aktive Themes oder Parents aktiver Themes zu löschen)
for theme in twentytwentyone twentytwentytwo twentytwentythree twentytwentyfour; do
    sudo -u "$SYSTEM_USER" wp theme delete "$theme" \
        --path="$SITE_PATH" --allow-root 2>/dev/null || true
done

# Standard-Inhalte
sudo -u "$SYSTEM_USER" wp post delete 1 2 --force \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true   # Hello World + Sample Page
sudo -u "$SYSTEM_USER" wp comment delete 1 --force \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true   # Standard-Kommentar

# Pingbacks / Trackbacks deaktivieren
sudo -u "$SYSTEM_USER" wp option update default_ping_status "closed" \
    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update default_pingback_flag "0" \
    --path="$SITE_PATH" --allow-root

# Admin-E-Mail-Bestätigung deaktivieren (WordPress-Nag alle 6 Monate)
sudo -u "$SYSTEM_USER" wp option update admin_email_lifespan "2147483647" \
    --path="$SITE_PATH" --allow-root

# WordPress-eigene Registrierungsseite deaktivieren (WooCommerce nicht betroffen)
sudo -u "$SYSTEM_USER" wp option update users_can_register "0" \
    --path="$SITE_PATH" --allow-root

# Sicherheits-Dateien entfernen
rm -f "${SITE_PATH}/readme.html" \
      "${SITE_PATH}/license.txt" \
      "${SITE_PATH}/wp-config-sample.php"

# WooCommerce-Tracking + Marketing + Einstellungen
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    sudo -u "$SYSTEM_USER" wp option update woocommerce_allow_tracking "no"                  --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_show_marketplace_suggestions "no"    --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_remote_logging_enabled "no"          --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_default_country "DE"                 --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_currency "EUR"                       --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_weight_unit "kg"                     --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_dimension_unit "cm"                  --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_enable_guest_checkout "yes"          --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_enable_checkout_login_reminder "yes" --path="$SITE_PATH" --allow-root 2>/dev/null || true

    # E-Mail-Absender
    sudo -u "$SYSTEM_USER" wp option update woocommerce_email_from_name    "${WOO_SHOP_NAME}"                                              --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_email_from_address "noreply@${DOMAIN}"                                             --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_email_footer_text  "${WOO_SHOP_NAME} | https://${DOMAIN} | Impressum: https://${DOMAIN}/impressum" --path="$SITE_PATH" --allow-root 2>/dev/null || true
fi

log "Bloat entfernt (Plugins, Themes, Demo-Inhalte, Pingbacks, Sicherheitsdateien)"

# ── WooCommerce: Rechtliche Seiten (Digital-Only) ─────────────────────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    info "Rechtliche Seiten werden angelegt..."

    IMPRESSUM_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Impressum" --post_name="impressum" \
        --post_status=publish \
        --post_content="<p><em>[Impressum-Text hier einfügen]</em></p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    DATENSCHUTZ_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Datenschutzerklaerung" --post_name="datenschutz" \
        --post_status=publish \
        --post_content="<p><em>[Datenschutzerklärung hier einfügen]</em></p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    AGB_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="AGB" --post_name="agb" \
        --post_status=publish \
        --post_content="<p><em>[AGB hier einfügen]</em></p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    WIDERRUF_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Widerrufsbelehrung" --post_name="widerrufsbelehrung" \
        --post_status=publish \
        --post_content="<p><em>[Widerrufsbelehrung fuer digitale Gueter hier einfuegen]</em></p><p>Hinweis: Bei digitalen Produkten erlischt das Widerrufsrecht mit Beginn der Ausfuehrung (Paragraph 356 Abs. 5 BGB).</p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    LIEFERUNG_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Lieferung und Download" --post_name="lieferung" \
        --post_status=publish \
        --post_content="<p><em>[Lieferbedingungen fuer digitale Produkte hier einfuegen]</em></p><p>Digitale Produkte werden nach abgeschlossener Zahlung sofort per Download bereitgestellt.</p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    # WooCommerce/WordPress Seiten zuweisen
    sudo -u "$SYSTEM_USER" wp option update woocommerce_terms_page_id     "$AGB_ID"         --path="$SITE_PATH" --allow-root
    sudo -u "$SYSTEM_USER" wp option update wp_page_for_privacy_policy    "$DATENSCHUTZ_ID" --path="$SITE_PATH" --allow-root

    # Versandkostenrechner im Warenkorb ausblenden (digital = kein Versand)
    sudo -u "$SYSTEM_USER" wp option update woocommerce_enable_shipping_calc "no" --path="$SITE_PATH" --allow-root 2>/dev/null || true

    log "Rechtliche Seiten angelegt: Impressum (${IMPRESSUM_ID}), Datenschutz (${DATENSCHUTZ_ID}), AGB (${AGB_ID}), Widerruf (${WIDERRUF_ID}), Lieferung (${LIEFERUNG_ID})"
fi

# ── Admin-Notices aufräumen ───────────────────────────────────────────────
# Entfernt die Dauer-Banner der Stack-Plugins im Dashboard, indem genau die
# Dismissal-Persistenz gesetzt wird, die der jeweilige Klick setzen wuerde —
# KEIN pauschales Notice-Unterdruecken (echte Warnungen bleiben sichtbar).
# Redis-Banner laufen ueber WP_REDIS_DISABLE_BANNERS in der wp-config (oben).
NOTICE_PHP=$(mktemp /tmp/notices.XXXXXX.php)
cat > "$NOTICE_PHP" <<'NOTICEEOF'
<?php
// Converter for Media: Welcome-Notice (zeigt bis webpc_is_new_installation != '1')
update_option('webpc_is_new_installation', '0');

// Blocksy Companion (Freemius): Opt-in-Notice per anonymem Skip beenden
if (function_exists('blocksy_companion_fs') && is_object(blocksy_companion_fs())) {
    try { blocksy_companion_fs()->skip_connection(); } catch (\Throwable $e) {}
}

// Core: "Welcome to WordPress!"-Panel aus + Standard-Anordnung der Dashboard-Widgets
// (Referenz-Layout von 4you.download, 2026-08-18: Redis+Matomo | Consent+GA |
// FluentSMTP | Site Health+Fluent Forms). Unbekannte Widget-IDs ignoriert WP einfach.
$widget_order = array(
    'normal'  => 'dashboard_rediscache,seopress_matomo_dashboard_widget',
    'side'    => 'faz_consent_widget,seopress_ga_dashboard_widget',
    'column3' => 'fluentsmtp_reports_widget',
    'column4' => 'dashboard_site_health,fluentform_stat_widget',
);
foreach (get_users(array('role' => 'administrator', 'fields' => 'ID')) as $uid) {
    update_user_meta($uid, 'show_welcome_panel', 0);
    update_user_meta($uid, 'meta-box-order_dashboard', $widget_order);
}
echo "notices-cleaned\n";
NOTICEEOF
chmod 644 "$NOTICE_PHP"
if sudo -u "$SYSTEM_USER" wp eval-file "$NOTICE_PHP" --path="$SITE_PATH" --allow-root 2>/dev/null | grep -q 'notices-cleaned'; then
    log "Admin-Notices aufgeräumt (WebP/Blocksy/Welcome-Panel; Redis via wp-config)"
else
    warn "Admin-Notices-Aufräumen fehlgeschlagen — Banner ggf. im Dashboard wegklicken"
fi
rm -f "$NOTICE_PHP"

# ── Must-Use Plugin: Cache-Check deaktivieren ────────────────────────────
mkdir -p "${SITE_PATH}/wp-content/mu-plugins"

# Dashboard entrümpeln: die vier Core-Widgets (At a Glance, Activity, Quick Draft,
# Events and News) braucht auf den Hosting-Sites niemand — die nützlichen Widgets
# (Redis, Site Health, FluentSMTP, Fluent Forms, Matomo, Cookie Consent) bleiben.
cat > "${SITE_PATH}/wp-content/mu-plugins/dashboard-cleanup.php" <<'MUPLUGIN'
<?php
/**
 * Plugin Name: Dashboard Cleanup
 * Description: Entfernt die vier Core-Dashboard-Widgets (At a Glance, Activity, Quick Draft, Events and News).
 */
add_action('wp_dashboard_setup', function () {
    remove_meta_box('dashboard_right_now',   'dashboard', 'normal'); // At a Glance
    remove_meta_box('dashboard_activity',    'dashboard', 'normal'); // Activity
    remove_meta_box('dashboard_quick_press', 'dashboard', 'side');   // Quick Draft
    remove_meta_box('dashboard_primary',     'dashboard', 'side');   // WP Events and News
}, 99);
MUPLUGIN

# Blocksy-Footer: Standard-Copyright auf den Site-Titel statt "WordPress Theme by
# Creative Themes". Greift nur, solange im Customizer nichts anderes gesetzt ist.
cat > "${SITE_PATH}/wp-content/mu-plugins/footer-copyright.php" <<'MUPLUGIN'
<?php
/**
 * Plugin Name: Footer Copyright
 * Description: Blocksy-Footer-Copyright-Standard: Jahr + Site-Titel statt Theme-Werbung.
 */
add_filter('blocksy:footer:copyright:default-value', function () {
    return 'Copyright &copy; {current_year} &ndash; {site_title}';
});
MUPLUGIN

# eazyanalytics-Pixel: Host + Key setzt das Provisioning (provision-endpoint.sh) als Optionen —
# hier bewusst kein Hostname (public Repo). Tracking ist consent-pflichtig (advanced/Replays):
# die FAZ-Filter stufen das Script als "analytics" ein, FAZ blockt es bis zum Opt-in.
# Die Platzhalterseite (maintenance-mode.php) lädt es nie — dort gibt es kein Consent-Banner.
cat > "${SITE_PATH}/wp-content/mu-plugins/eazyanalytics-pixel.php" <<'MUPLUGIN'
<?php
/**
 * Plugin Name: eazyanalytics Pixel
 * Description: Tracking-Snippet, sobald das Provisioning pixel_host + pixel_key gesetzt hat; FAZ blockt es bis zum Cookie-Opt-in (Kategorie analytics).
 */
function wph_eazy_pixel_host() {
    $h = get_option('eazyanalytics_pixel_host');
    return (is_string($h) && preg_match('/^[a-z0-9.-]+$/i', $h)) ? $h : '';
}
add_action('wp_head', function () {
    $h = wph_eazy_pixel_host();
    $k = get_option('eazyanalytics_pixel_key');
    if (!$h || !is_string($k) || !preg_match('/^[A-Za-z0-9]+$/', $k)) {
        return;
    }
    echo '<script defer src="https://' . $h . '/pixel/' . $k . '"></script>' . "\n";
}, 20);
add_filter('faz_blocking_rules', function ($map) {
    $h = wph_eazy_pixel_host();
    if ($h) { $map[$h] = 'analytics'; }
    return $map;
});
add_filter('faz_blocking_rules_client', function ($providers) {
    $h = wph_eazy_pixel_host();
    if ($h) { $providers[$h] = array('analytics'); }
    return $providers;
});
MUPLUGIN

# AdSense Auto-Ads (nur Blogs) + Microsoft Clarity: beide lesen ihre ID aus einer Option, die das
# Provisioning setzt (wph_adsense_pub_id, wph_clarity_project_id) — ohne Option bleibt alles still.
# Shops bekommen Clarity ueber den Pixel Manager, nicht hierueber (sonst doppelt). FAZ blockt beide
# Scripts bis zum Opt-in (AdSense: marketing, Clarity: analytics). ads.txt schreibt das Provisioning.
cat > "${SITE_PATH}/wp-content/mu-plugins/wph-tracking-ids.php" <<'MUPLUGIN'
<?php
/**
 * Plugin Name: Tracking-IDs (AdSense Auto-Ads, Microsoft Clarity)
 * Description: Bindet AdSense bzw. Clarity ein, sobald das Provisioning die jeweilige ID als Option gesetzt hat; FAZ blockt bis zum Cookie-Opt-in.
 */
function wph_adsense_pub_id() {
    $v = get_option('wph_adsense_pub_id');
    return (is_string($v) && preg_match('/^pub-[0-9]{10,20}$/', $v)) ? $v : '';
}
function wph_clarity_project_id() {
    $v = get_option('wph_clarity_project_id');
    return (is_string($v) && preg_match('/^[a-z0-9]{6,24}$/', $v)) ? $v : '';
}
add_action('wp_head', function () {
    $pub = wph_adsense_pub_id();
    if ($pub) {
        echo '<script async src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-' . $pub . '" crossorigin="anonymous"></script>' . "\n";
    }
    $cl = wph_clarity_project_id();
    if ($cl) {
        echo '<script>(function(c,l,a,r,i,t,y){c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y);})(window,document,"clarity","script","' . $cl . '");</script>' . "\n";
    }
}, 20);
add_filter('faz_blocking_rules', function ($map) {
    if (wph_adsense_pub_id())      { $map['pagead2.googlesyndication.com'] = 'marketing'; }
    if (wph_clarity_project_id())  { $map['clarity.ms'] = 'analytics'; }
    return $map;
});
add_filter('faz_blocking_rules_client', function ($providers) {
    if (wph_adsense_pub_id())      { $providers['pagead2.googlesyndication.com'] = array('marketing'); }
    if (wph_clarity_project_id())  { $providers['clarity.ms'] = array('analytics'); }
    return $providers;
});
MUPLUGIN

cat > "${SITE_PATH}/wp-content/mu-plugins/server-cache.php" <<'MUPLUGIN'
<?php
/**
 * Caching wird durch Nginx FastCGI Cache + Redis auf Server-Ebene gehandhabt.
 * Deaktiviert den WordPress Site Health Page-Cache-Check.
 */
add_filter('site_status_tests', function($tests) {
    unset($tests['async']['page_cache']);
    return $tests;
});
MUPLUGIN

cat > "${SITE_PATH}/wp-content/mu-plugins/performance.php" <<'MUPLUGIN'
<?php
/**
 * Performance & Security:
 * - Heartbeat im Frontend deaktivieren, im Admin auf 60 Sek. drosseln
 * - Admin-Bar für Nicht-Admins ausblenden
 * - Author-Enumeration blockieren
 */

// Heartbeat
add_filter('heartbeat_settings', function($settings) {
    $settings['interval'] = 60;
    return $settings;
});
add_action('init', function() {
    if (!is_admin()) {
        wp_deregister_script('heartbeat');
    }
});

// Admin-Bar für Nicht-Admins ausblenden
add_action('after_setup_theme', function() {
    if (!current_user_can('manage_options')) {
        show_admin_bar(false);
    }
});

// Author-Enumeration blockieren
add_action('template_redirect', function() {
    if (is_author() && isset($_GET['author'])) {
        wp_redirect(home_url('/'), 301);
        exit;
    }
});
add_action('init', function() {
    if (preg_match('/\?author=([0-9]*)/i', $_SERVER['REQUEST_URI'])) {
        wp_redirect(home_url('/'), 301);
        exit;
    }
});
MUPLUGIN

log "Must-Use Plugins erstellt (Cache-Check, Heartbeat, Admin-Bar, Author-Enumeration)"

# ── Must-Use Plugin: Digital Checkout Consent (nur WooCommerce) ───────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    cat > "${SITE_PATH}/wp-content/mu-plugins/digital-checkout.php" <<'MUPLUGIN'
<?php
/**
 * Digital Goods Checkout: Widerrufsrecht-Checkbox (§ 356 Abs. 5 BGB)
 *
 * Zeigt beim Checkout eine Pflicht-Checkbox an, wenn der Warenkorb
 * downloadbare Produkte enthält. Die Zustimmung wird mit Zeitstempel
 * in der Bestellung gespeichert (Nachweispflicht).
 */

/**
 * Prüft ob der aktuelle Warenkorb downloadbare Produkte enthält.
 */
function _wph_cart_has_downloadable(): bool {
    if ( ! function_exists( 'WC' ) || ! WC()->cart ) {
        return false;
    }
    foreach ( WC()->cart->get_cart() as $item ) {
        $product = $item['data'] ?? null;
        if ( $product && $product->is_downloadable() ) {
            return true;
        }
    }
    return false;
}

/**
 * Checkbox vor dem Bestell-Button anzeigen.
 */
add_action( 'woocommerce_review_order_before_submit', function () {
    if ( ! _wph_cart_has_downloadable() ) {
        return;
    }

    $widerruf_url = '';
    $widerruf_page = get_page_by_path( 'widerrufsbelehrung' );
    if ( $widerruf_page ) {
        $widerruf_url = get_permalink( $widerruf_page->ID );
    }
    ?>
    <div class="digital-withdrawal-consent" style="margin:0 0 1.2em;padding:.8em;background:#f8f8f8;border-left:3px solid #d63638;">
        <label style="display:flex;align-items:flex-start;gap:.6em;cursor:pointer;font-size:.9em;line-height:1.4;">
            <input type="checkbox"
                   name="digital_withdrawal_consent"
                   id="digital_withdrawal_consent"
                   value="1"
                   style="margin-top:.15em;flex-shrink:0;" />
            <span>
                Ich stimme ausdrücklich zu, dass mit der Ausführung des Vertrags
                vor Ablauf der Widerrufsfrist begonnen wird. Mir ist bekannt, dass
                mein Widerrufsrecht mit Beginn der Ausführung erlischt.
                <?php if ( $widerruf_url ) : ?>
                    (<a href="<?php echo esc_url( $widerruf_url ); ?>" target="_blank" rel="noopener">Widerrufsbelehrung</a>)
                <?php endif; ?>
            </span>
        </label>
    </div>
    <?php
} );

/**
 * Server-seitige Validierung — läuft unabhängig vom Theme.
 */
add_action( 'woocommerce_checkout_process', function () {
    if ( ! _wph_cart_has_downloadable() ) {
        return;
    }
    if ( empty( $_POST['digital_withdrawal_consent'] ) ) {
        wc_add_notice(
            'Bitte bestätige, dass du auf dein Widerrufsrecht bei digitalen Produkten verzichtest.',
            'error'
        );
    }
} );

/**
 * Zustimmung mit Zeitstempel in der Bestellung speichern.
 */
add_action( 'woocommerce_checkout_order_created', function ( $order ) {
    if ( ! empty( $_POST['digital_withdrawal_consent'] ) ) {
        $order->update_meta_data( '_digital_withdrawal_consent', current_time( 'mysql' ) );
        $order->save();
    }
} );

/**
 * Button-Lösung (§ 312j Abs. 3 BGB): Bestell-Button muss die Zahlungspflicht
 * unmissverständlich ausweisen. WooCommerce-Default ("Bestellung aufgeben")
 * gilt als nicht eindeutig. Ohne Germanized hier zentral gesetzt.
 */
add_filter( 'woocommerce_order_button_text', function () {
    return 'Zahlungspflichtig bestellen';
} );
MUPLUGIN
    log "Must-Use Plugin: Digital Checkout Consent (Widerruf-Checkbox + Button-Lösung § 312j)"
fi

# ── Must-Use Plugin: Maintenance Mode ────────────────────────────────────
cat > "${SITE_PATH}/wp-content/mu-plugins/maintenance-mode.php" <<'MUPLUGIN'
<?php
/**
 * Maintenance Mode — "Coming Soon"-Platzhalter statt 503.
 *
 * Aktivieren:   touch wp-content/.maintenance-active
 * Deaktivieren: rm wp-content/.maintenance-active
 *
 * Liefert bewusst HTTP 200 (nicht 503): (a) dajaup/66uptime werten 503 als "down";
 * (b) FastCGI-Cache cacht nur 200er (siehe maintenance.sh),
 * 503 blieb also ungecacht und war deshalb hier unproblematisch — das gilt jetzt
 * andersrum: maintenance.sh purged den Cache bereits bei JEDEM Wechsel (live wie
 * maintenance), das deckt auch diesen 200er ab.
 *
 * Eingeloggte User (Admin) sehen die Seite immer normal.
 * wp-login.php und /wp-admin sind immer erreichbar.
 */

// CLI und Cron nie blockieren — sonst sind wp-cli-Wartungsskripte (update-wp,
// db-cleanup, health-check, rotate-keys …) auf einer Site im Maintenance-Mode
// unbrauchbar, weil sie statt eines Ergebnisses die HTML-Platzhalterseite erhielten.
if ( ( defined( 'WP_CLI' ) && WP_CLI ) || ( defined( 'DOING_CRON' ) && DOING_CRON ) ) {
    return;
}

$_wph_flag = dirname( __FILE__ ) . '/../.maintenance-active';

if ( ! file_exists( $_wph_flag ) ) {
    return;
}

$_wph_uri = $_SERVER['REQUEST_URI'] ?? '';

// wp-login.php immer durchlassen, /wp-admin ebenso: WordPress leitet Ausgeloggte dort
// selbst auf den Login um (sonst sahen sie unter /wp-admin nur die Platzhalterseite)
if ( strpos( $_wph_uri, 'wp-login.php' ) !== false || preg_match( '#^/wp-admin(/|$|\?)#', $_wph_uri ) ) {
    return;
}

// Eingeloggte User durchlassen (Cookie-Check vor WordPress-Init)
foreach ( array_keys( $_COOKIE ) as $_wph_key ) {
    if ( strpos( $_wph_key, 'wordpress_logged_in_' ) === 0 ) {
        return;
    }
}

http_response_code( 200 );
header( 'Content-Type: text/html; charset=UTF-8' );

$_wph_host = htmlspecialchars( $_SERVER['HTTP_HOST'] ?? '', ENT_QUOTES, 'UTF-8' );

// Matomo-Tracking auf der Platzhalterseite: erst moeglich, sobald provision-endpoint.sh
// die idSite in die SEOpress-Option geschrieben hat (Phase 2, Schritt 4). Bis dahin
// laeuft die Seite ohnehin noch nicht oeffentlich (DNS/Caddy erst Schritt 1-2 davor),
// die kurze Luecke bleibt folgenlos. Kein WordPress-Boot noetig — get_option() reicht,
// die DB-Verbindung steht auf mu-plugins-Ebene schon.
$_wph_matomo_snippet = '';
if ( function_exists( 'get_option' ) ) {
    $_wph_seo = get_option( 'seopress_google_analytics_option_name' );
    if ( is_array( $_wph_seo )
        && ( $_wph_seo['seopress_google_analytics_matomo_enable'] ?? '' ) === '1'
        && ! empty( $_wph_seo['seopress_google_analytics_matomo_id'] )
        && ! empty( $_wph_seo['seopress_google_analytics_matomo_site_id'] ) ) {
        $_wph_m_host = htmlspecialchars( $_wph_seo['seopress_google_analytics_matomo_id'], ENT_QUOTES, 'UTF-8' );
        $_wph_m_site = (int) $_wph_seo['seopress_google_analytics_matomo_site_id'];
        $_wph_matomo_snippet = <<<HTML
<script>
var _paq = window._paq = window._paq || [];
_paq.push(['trackPageView']);
_paq.push(['enableLinkTracking']);
(function() {
  var u = "https://{$_wph_m_host}/";
  _paq.push(['setTrackerUrl', u + 'matomo.php']);
  _paq.push(['setSiteId', '{$_wph_m_site}']);
  var d = document, g = d.createElement('script'), s = d.getElementsByTagName('script')[0];
  g.async = true; g.src = u + 'matomo.js'; s.parentNode.insertBefore(g, s);
})();
</script>
HTML;
    }
}
?><!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?php echo $_wph_host; ?></title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #0f172a;
    color: #e2e8f0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  .card { max-width: 460px; width: 100%; text-align: center; }
  .icon { font-size: 3rem; margin-bottom: 1.5rem; }
  h1   { font-size: 1.8rem; font-weight: 700; margin-bottom: .75rem; letter-spacing: -.02em; }
  p    { color: #94a3b8; line-height: 1.65; font-size: .95rem; }
  .domain { color: #38bdf8; font-size: .85rem; margin-top: 2rem; opacity: .8; }
</style>
</head>
<body>
<div class="card">
  <div class="icon">✨</div>
  <h1>Gleich geht's los.</h1>
  <p>Noch schrauben wir hier<br>— bald ist alles startklar.</p>
  <p class="domain"><?php echo $_wph_host; ?></p>
</div>
<?php echo $_wph_matomo_snippet; ?>
</body>
</html>
<?php
die();
MUPLUGIN
log "Must-Use Plugin: Maintenance Mode erstellt"

# ── WP-Cron ────────────────────────────────────────────────────────────────
# DISABLE_WP_CRON=true (wp-config) → kein Cron bei jedem Seitenaufruf.
# KEIN lokaler System-Cron mehr: der WP-Cron wird zentral über provision-endpoint.sh
# in cron-job.org angelegt (HTTP-GET auf wp-cron.php), direkt nach diesem Install
# ausgelöst. So kann es keinen doppelten Cron (lokal + extern) geben.
log "WP-Cron: wird zentral in cron-job.org angelegt (provision-endpoint.sh) — kein lokaler Cron"

# ── Berechtigungen setzen ─────────────────────────────────────────────────
chown -R "${SYSTEM_USER}:${SYSTEM_USER}" "$SITE_PATH"
find "$SITE_PATH" -type d -exec chmod 750 {} \;
find "$SITE_PATH" -type f -exec chmod 640 {} \;
chmod 600 "${SITE_PATH}/wp-config.php"
log "Berechtigungen gesetzt"

# ── Maintenance Mode aktivieren ───────────────────────────────────────────
touch "${SITE_PATH}/wp-content/.maintenance-active"
chown "${SYSTEM_USER}:${SYSTEM_USER}" "${SITE_PATH}/wp-content/.maintenance-active"
chmod 640 "${SITE_PATH}/wp-content/.maintenance-active"
log "Maintenance Mode aktiviert (→ sudo bash maintenance.sh zum Freischalten)"

# ── Services neu laden ────────────────────────────────────────────────────
# restart (nicht reload): nginx-Master muss neu starten, damit der www-data-Worker die
# frisch hinzugefügte Site-Gruppenmitgliedschaft (usermod -aG oben) übernimmt.
nginx -t && systemctl restart nginx
systemctl reload php8.3-fpm
log "Nginx neu gestartet (Gruppenübernahme) und PHP-FPM neu geladen"

# ── Filebrowser User anlegen ─────────────────────────────────────────────
FB_DB="/etc/filebrowser/database.db"
FB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
FB_USER="${DOMAIN_SAFE:0:32}"

if [[ -f "$FB_DB" ]] && command -v filebrowser &>/dev/null; then
    # Die Bolt-Datenbank von Filebrowser erlaubt nur EINEN Writer: solange der Dienst
    # läuft, scheitert jeder CLI-Schreibzugriff mit "Error: timeout". Deshalb den Dienst
    # um den Aufruf herum kurz stoppen und danach wieder starten.
    # Fehler werden NICHT mehr verschluckt: vorher lief alles in `|| true` und das Script
    # meldete "User angelegt", obwohl keiner existierte — das Passwort landete trotzdem in
    # der Cred-Datei (und von dort in 1Password), ohne dass es dazu je einen User gab.
    FB_WAS_ACTIVE=false
    if systemctl is-active --quiet filebrowser 2>/dev/null; then FB_WAS_ACTIVE=true; fi
    $FB_WAS_ACTIVE && { systemctl stop filebrowser 2>/dev/null || true; }

    FB_OK=false
    # Bewusste Abweichung: filebrowser nimmt das Passwort nur als argv entgegen (kein stdin,
    # kein env) — es ist für die Laufzeit des Aufrufs (< 1 s) in der Prozessliste sichtbar.
    if filebrowser users add "$FB_USER" "$FB_PASS" \
            --scope "$SITE_PATH" \
            --database "$FB_DB" \
            --perm.create \
            --perm.rename \
            --perm.modify \
            --perm.delete \
            --perm.download >/dev/null 2>&1 \
       || filebrowser users update "$FB_USER" \
            --password "$FB_PASS" \
            --scope "$SITE_PATH" \
            --database "$FB_DB" >/dev/null 2>&1; then
        # Erfolg erst glauben, wenn der User wirklich in der Datenbank steht.
        if filebrowser users ls --database "$FB_DB" 2>/dev/null \
             | awk '{print $2}' | grep -qxF "$FB_USER"; then
            FB_OK=true
        fi
    fi

    $FB_WAS_ACTIVE && { systemctl start filebrowser 2>/dev/null || true; }

    if $FB_OK; then
        log "Filebrowser User angelegt: ${FB_USER}"
    else
        warn "Filebrowser-User ${FB_USER} konnte NICHT angelegt werden (DB gesperrt?) — manuell nachholen:"
        warn "  systemctl stop filebrowser && filebrowser users add <user> <pass> --scope ${SITE_PATH} --database ${FB_DB} && systemctl start filebrowser"
        FB_PASS="n/a"
    fi
else
    warn "Filebrowser nicht gefunden — User manuell anlegen"
    FB_PASS="n/a"
fi

# ── SFTP Chroot einrichten ────────────────────────────────────────────────
SFTP_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
SFTP_CHROOT="/var/sftp/${SYSTEM_USER}"

# sftpusers Gruppe sicherstellen (falls setup-web.sh noch nicht gelaufen)
groupadd --system sftpusers 2>/dev/null || true

# User zur SFTP-Gruppe hinzufügen und Passwort setzen
usermod -aG sftpusers "$SYSTEM_USER"
echo "${SYSTEM_USER}:${SFTP_PASS}" | chpasswd

# Chroot-Verzeichnis (muss root:root 755 sein — SSH-Anforderung)
mkdir -p "${SFTP_CHROOT}"
chown root:root "${SFTP_CHROOT}"
chmod 755 "${SFTP_CHROOT}"

# site/-Unterverzeichnis als Bind-Mount-Ziel
mkdir -p "${SFTP_CHROOT}/site"
chown "${SYSTEM_USER}:${SYSTEM_USER}" "${SFTP_CHROOT}/site"
chmod 750 "${SFTP_CHROOT}/site"

# Bind-Mount (idempotent)
if ! mountpoint -q "${SFTP_CHROOT}/site"; then
    mount --bind "${SITE_PATH}" "${SFTP_CHROOT}/site"
fi

# fstab-Eintrag (idempotent)
FSTAB_ENTRY="${SITE_PATH} ${SFTP_CHROOT}/site none bind 0 0"
if ! grep -qF "$FSTAB_ENTRY" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
fi

log "SFTP Chroot eingerichtet: ${SFTP_CHROOT}"

# ── Zugangsdaten speichern ────────────────────────────────────────────────
CRED_FILE="/etc/wp-hosting/sites/${DOMAIN}.txt"
cat > "$CRED_FILE" <<EOF
Domain:        https://${DOMAIN}
Typ:           ${SITE_TYPE}
Installiert:   $(date '+%Y-%m-%d %H:%M')

── WordPress ─────────────────────────────────
WP-Admin URL:  https://${DOMAIN}/wp-admin
Admin-User:    ${WP_ADMIN_USER}
Admin-Pass:    ${WP_ADMIN_PASS}
Admin-E-Mail:  ${WP_ADMIN_EMAIL}

── Datenbank ─────────────────────────────────
DB-Host:       ${DB_HOST}
DB-Name:       ${DB_NAME}
DB-User:       ${DB_USER}
DB-Pass:       ${DB_PASS}

── Filebrowser ───────────────────────────────
FB-User:       ${FB_USER}
FB-Pass:       ${FB_PASS}

── SFTP ──────────────────────────────────────
SFTP-Host:     $(hostname -I | awk '{print $1}')
SFTP-Port:     22
SFTP-User:     ${SYSTEM_USER}
SFTP-Pass:     ${SFTP_PASS}
SFTP-Pfad:     /site

── Server ────────────────────────────────────
Site-Pfad:     ${SITE_PATH}
PHP-Pool:      ${PHP_POOL}
Nginx-Vhost:   ${NGINX_VHOST}
System-User:   ${SYSTEM_USER}
Admin-IP:      ${ADMIN_IP:-unbeschränkt}
EOF

chmod 600 "$CRED_FILE"
_INSTALL_DONE=true  # Cleanup-Trap deaktivieren

# ── Ausgabe ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   ${SITE_TYPE^} installiert ✓"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
# Bewusst OHNE Passwörter: stdout landet in Logs, Terminal-Scrollback, CI- und
# Session-Mitschnitten. Die Geheimnisse stehen ausschließlich in $CRED_FILE (chmod 600)
# und werden von dort nach 1Password übernommen (provision-endpoint.sh, ensure_credentials).
echo -e "  URL:           ${BOLD}https://${DOMAIN}${NC}"
echo -e "  WP-Admin:      ${BOLD}https://${DOMAIN}/wp-admin${NC}"
echo -e "  Admin-User:    ${BOLD}${WP_ADMIN_USER}${NC}"
echo ""
echo -e "  DB-Name:       ${BOLD}${DB_NAME}${NC}"
echo -e "  DB-User:       ${BOLD}${DB_USER}${NC}"
echo ""
echo -e "  FB-User:       ${BOLD}${FB_USER}${NC}"
echo ""
echo -e "  SFTP-Host:     ${BOLD}$(hostname -I | awk '{print $1}')${NC}"
echo -e "  SFTP-User:     ${BOLD}${SYSTEM_USER}${NC}"
echo -e "  SFTP-Pfad:     ${BOLD}/site${NC}"
echo ""
echo -e "${YELLOW}  → Passwörter stehen NUR in ${CRED_FILE} (chmod 600) — nicht in dieser Ausgabe.${NC}"
echo -e "${YELLOW}     Auslesen: sudo cat ${CRED_FILE}${NC}"
echo -e "${YELLOW}  → Site ist im Maintenance Mode — freischalten: sudo bash maintenance.sh${NC}"
echo -e "${YELLOW}  → Endpunkt via provision-endpoint.sh einrichten (Caddy-Block + DNS + Cron + Matomo).${NC}"
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
echo -e "${YELLOW}  → Rechtliche Texte befüllen (Impressum, Datenschutz, AGB, Widerruf):${NC}"
echo -e "${YELLOW}     Empfehlung: https://www.it-recht-kanzlei.de (Digital-Paket)${NC}"
fi
echo ""
