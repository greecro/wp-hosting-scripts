#!/bin/bash
# Klont eine bestehende WordPress-Site auf eine neue Domain (z.B. für Staging)
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash clone-site.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site klonen                      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Quell-Site auswählen ───────────────────────────────────────────────────
SITES_DIR="/etc/wp-hosting/sites"
[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && err "Keine installierten Sites gefunden."

echo "Installierte Sites:"
for f in "${SITES_DIR}"/*.txt; do echo "  - $(basename "$f" .txt)"; done
echo ""

read -rp "Quell-Domain (zu klonende Site): " SRC_DOMAIN
SRC_DOMAIN=$(echo "$SRC_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ ! "$SRC_DOMAIN" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]] && err "Ungültige Quell-Domain: ${SRC_DOMAIN}"
[[ ! -f "${SITES_DIR}/${SRC_DOMAIN}.txt" ]] && err "Site '${SRC_DOMAIN}' nicht gefunden."

read -rp "Ziel-Domain (neue Domain, z.B. staging.meinshop.de): " DST_DOMAIN
DST_DOMAIN=$(echo "$DST_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DST_DOMAIN" ]] && err "Ziel-Domain darf nicht leer sein."
[[ ! "$DST_DOMAIN" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]] && err "Ungültige Ziel-Domain: ${DST_DOMAIN}"
[[ -f "${SITES_DIR}/${DST_DOMAIN}.txt" ]] && err "Site '${DST_DOMAIN}' existiert bereits."
[[ -d "/var/www/${DST_DOMAIN}" ]] && err "Verzeichnis /var/www/${DST_DOMAIN} existiert bereits."

# Quell-Daten lesen
SRC_PATH="/var/www/${SRC_DOMAIN}"
SRC_SAFE="$(printf '%s' "$SRC_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$SRC_DOMAIN" | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-8)"
SRC_DB_NAME=$(grep "^DB-Name:" "${SITES_DIR}/${SRC_DOMAIN}.txt" | awk '{print $2}')
SRC_TYPE=$(grep "^Typ:" "${SITES_DIR}/${SRC_DOMAIN}.txt" | awk '{print $2}')
[[ ! -d "$SRC_PATH" ]] && err "Quell-Verzeichnis nicht gefunden: ${SRC_PATH}"

echo ""
info "Quelle:  ${BOLD}${SRC_DOMAIN}${NC} (${SRC_TYPE})"
info "Ziel:    ${BOLD}${DST_DOMAIN}${NC}"
echo ""
read -rp "Klonen starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Ziel-Variablen ─────────────────────────────────────────────────────────
DST_SAFE="$(printf '%s' "$DST_DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$DST_DOMAIN" | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-8)"
DST_PATH="/var/www/${DST_DOMAIN}"
DST_DB_NAME="wp_${DST_SAFE}"
DST_DB_USER="wpdb_$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 10 || true)"
DST_DB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32) || true
DST_SYSTEM_USER="wp_${DST_SAFE}"
DST_SOCK="/run/php/php8.3-fpm-${DST_DOMAIN}.sock"
WEB_VM_IP=$(hostname -I | awk '{print $1}')

# ── Systemuser anlegen ────────────────────────────────────────────────────
useradd -r -s /sbin/nologin -d "$DST_PATH" "$DST_SYSTEM_USER" 2>/dev/null || true
# Mandantentrennung (wie install-wp): eigene Site-Gruppe, www-data (nginx) darf lesen
usermod -aG "$DST_SYSTEM_USER" www-data
log "Systemuser: ${DST_SYSTEM_USER}"

# ── Dateien kopieren ──────────────────────────────────────────────────────
info "Dateien werden kopiert..."
cp -a "$SRC_PATH" "$DST_PATH"
chown -R "${DST_SYSTEM_USER}:${DST_SYSTEM_USER}" "$DST_PATH"
log "Dateien kopiert: ${SRC_PATH} → ${DST_PATH}"

# ── Datenbank klonen ──────────────────────────────────────────────────────
info "Datenbank wird geklont..."
MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DST_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DST_DB_USER}'@'${WEB_VM_IP}' IDENTIFIED BY '${DST_DB_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER ON \`${DST_DB_NAME}\`.* TO '${DST_DB_USER}'@'${WEB_VM_IP}';
FLUSH PRIVILEGES;
SQL

# Dump der Quell-DB und Import in Ziel-DB
MYSQL_PWD="$DB_ADMIN_PASS" mysqldump -h "$DB_HOST" -u "$DB_ADMIN_USER" \
    --single-transaction --quick "$SRC_DB_NAME" \
    | MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" "$DST_DB_NAME"
log "Datenbank geklont: ${SRC_DB_NAME} → ${DST_DB_NAME}"

# ── wp-config.php anpassen ────────────────────────────────────────────────
wp config set DB_NAME     "$DST_DB_NAME" --path="$DST_PATH" --allow-root
wp config set DB_USER     "$DST_DB_USER" --path="$DST_PATH" --allow-root
wp config set WP_CACHE_KEY_SALT "${DST_DOMAIN}:" --path="$DST_PATH" --allow-root
# DB_PASSWORD ohne wp-cli setzen: `wp config set` nimmt den Wert nur als argv entgegen
# (Prozessliste) und druckt ihn in der Success-Zeile. Daher die define-Zeile per Bash
# umschreiben (Passwort ist A-Za-z0-9, in PHP-Single-Quotes unkritisch).
_cfg="${DST_PATH}/wp-config.php"; _tmp=$(mktemp "${DST_PATH}/.wp-config.XXXXXX"); _n=0
_re="^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]DB_PASSWORD['\"]"
while IFS= read -r _l || [[ -n "$_l" ]]; do
    if [[ "$_l" =~ $_re ]]; then
        printf "define( 'DB_PASSWORD', '%s' );\n" "$DST_DB_PASS"; _n=$((_n + 1))
    else
        printf '%s\n' "$_l"
    fi
done < "$_cfg" > "$_tmp"
[[ $_n -eq 1 ]] || { rm -f "$_tmp"; err "wp-config.php: DB_PASSWORD-Zeile ${_n}x gefunden (erwartet 1)"; }
chown --reference="$_cfg" "$_tmp"; mv "$_tmp" "$_cfg"
chmod 600 "${DST_PATH}/wp-config.php"
log "wp-config.php aktualisiert"

# ── URLs in DB ersetzen ───────────────────────────────────────────────────
info "URLs werden ersetzt..."
wp search-replace "https://${SRC_DOMAIN}" "https://${DST_DOMAIN}" \
    --path="$DST_PATH" --allow-root --skip-columns=guid
wp search-replace "http://${SRC_DOMAIN}" "https://${DST_DOMAIN}" \
    --path="$DST_PATH" --allow-root --skip-columns=guid
wp cache flush --path="$DST_PATH" --allow-root 2>/dev/null || true
log "URLs ersetzt"

# ── PHP-FPM Pool ──────────────────────────────────────────────────────────
SRC_POOL_FILE="/etc/php/8.3/fpm/pool.d/${SRC_DOMAIN}.conf"
DST_POOL_FILE="/etc/php/8.3/fpm/pool.d/${DST_DOMAIN}.conf"

if [[ -f "$SRC_POOL_FILE" ]]; then
    sed "s|${SRC_DOMAIN}|${DST_DOMAIN}|g; s|${SRC_PATH}|${DST_PATH}|g; \
         s|wp_${SRC_SAFE}|${DST_SYSTEM_USER}|g" \
        "$SRC_POOL_FILE" > "$DST_POOL_FILE"
    log "PHP-FPM Pool erstellt"
fi

# ── Nginx Vhost ───────────────────────────────────────────────────────────
SRC_VHOST="/etc/nginx/sites-available/${SRC_DOMAIN}"
DST_VHOST="/etc/nginx/sites-available/${DST_DOMAIN}"

if [[ -f "$SRC_VHOST" ]]; then
    sed "s|${SRC_DOMAIN}|${DST_DOMAIN}|g; s|${SRC_PATH}|${DST_PATH}|g; \
         s|php8.3-fpm-${SRC_DOMAIN}|php8.3-fpm-${DST_DOMAIN}|g" \
        "$SRC_VHOST" > "$DST_VHOST"
    ln -sf "$DST_VHOST" "/etc/nginx/sites-enabled/${DST_DOMAIN}"
    log "Nginx Vhost erstellt"
fi

# ── WP-Cron ───────────────────────────────────────────────────────────────
# Kein lokaler System-Cron (konsistent mit install-wp): DISABLE_WP_CRON bleibt gesetzt,
# der WP-Cron wird zentral über provision-endpoint.sh in cron-job.org angelegt. Für die
# geklonte Domain muss der Job separat angelegt werden.
info "WP-Cron: kein lokaler Cron — zentral via cron-job.org (provision-endpoint.sh) für die neue Domain anlegen"

# ── Services neu laden ────────────────────────────────────────────────────
nginx -t && systemctl restart nginx   # restart: www-data übernimmt die neue Site-Gruppe
systemctl reload php8.3-fpm
log "Services neu geladen"

# ── Filebrowser User anlegen ─────────────────────────────────────────────
FB_DB="/etc/filebrowser/database.db"
FB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
FB_USER="${DST_SAFE:0:32}"

if [[ -f "$FB_DB" ]] && command -v filebrowser &>/dev/null; then
    # Bolt-DB erlaubt nur EINEN Writer: laufender Dienst => "Error: timeout". Dienst kurz
    # stoppen und den Erfolg danach pruefen — sonst steht ein Passwort in der Cred-Datei,
    # zu dem es gar keinen User gibt.
    _fb_was_active=false
    if systemctl is-active --quiet filebrowser 2>/dev/null; then _fb_was_active=true; fi
    $_fb_was_active && { systemctl stop filebrowser 2>/dev/null || true; }
    _fb_ok=false
    # Bewusste Abweichung: filebrowser nimmt das Passwort nur als argv entgegen (kein stdin,
    # kein env) — es ist für die Laufzeit des Aufrufs (< 1 s) in der Prozessliste sichtbar.
    if filebrowser users add "$FB_USER" "$FB_PASS" \
            --scope "$DST_PATH" \
            --database "$FB_DB" \
            --perm.create --perm.rename --perm.modify --perm.delete --perm.download >/dev/null 2>&1 \
       || filebrowser users update "$FB_USER" \
            --password "$FB_PASS" --scope "$DST_PATH" \
            --database "$FB_DB" >/dev/null 2>&1; then
        filebrowser users ls --database "$FB_DB" 2>/dev/null \
            | awk '{print $2}' | grep -qxF "$FB_USER" && _fb_ok=true
    fi
    $_fb_was_active && { systemctl start filebrowser 2>/dev/null || true; }
    if $_fb_ok; then
        log "Filebrowser User angelegt: ${FB_USER}"
    else
        warn "Filebrowser-User ${FB_USER} konnte NICHT angelegt werden (DB gesperrt?) — manuell nachholen."
        FB_PASS="n/a"
    fi
else
    warn "Filebrowser nicht gefunden — User manuell anlegen"
    FB_PASS="n/a"
fi

# ── SFTP Chroot einrichten ────────────────────────────────────────────────
SFTP_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
SFTP_CHROOT="/var/sftp/${DST_SYSTEM_USER}"

groupadd --system sftpusers 2>/dev/null || true
usermod -aG sftpusers "$DST_SYSTEM_USER"
echo "${DST_SYSTEM_USER}:${SFTP_PASS}" | chpasswd

mkdir -p "${SFTP_CHROOT}"
chown root:root "${SFTP_CHROOT}"
chmod 755 "${SFTP_CHROOT}"
mkdir -p "${SFTP_CHROOT}/site"
chown "${DST_SYSTEM_USER}:${DST_SYSTEM_USER}" "${SFTP_CHROOT}/site"
chmod 750 "${SFTP_CHROOT}/site"

if ! mountpoint -q "${SFTP_CHROOT}/site"; then
    mount --bind "${DST_PATH}" "${SFTP_CHROOT}/site"
fi
FSTAB_ENTRY="${DST_PATH} ${SFTP_CHROOT}/site none bind 0 0"
if ! grep -qF "$FSTAB_ENTRY" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
fi
log "SFTP Chroot eingerichtet: ${SFTP_CHROOT}"

# ── Maintenance Mode aktivieren ───────────────────────────────────────────
touch "${DST_PATH}/wp-content/.maintenance-active"
chown "${DST_SYSTEM_USER}:${DST_SYSTEM_USER}" "${DST_PATH}/wp-content/.maintenance-active"
chmod 640 "${DST_PATH}/wp-content/.maintenance-active"
log "Maintenance Mode aktiviert"

# ── Credentials speichern ─────────────────────────────────────────────────
cat > "${SITES_DIR}/${DST_DOMAIN}.txt" <<EOF
Domain:        https://${DST_DOMAIN}
Typ:           ${SRC_TYPE} (Klon von ${SRC_DOMAIN})
Installiert:   $(date '+%Y-%m-%d %H:%M')

── WordPress ─────────────────────────────────
WP-Admin URL:  https://${DST_DOMAIN}/wp-admin
Admin-User:    (identisch mit Quell-Site)
Admin-Pass:    (identisch mit Quell-Site)
Admin-E-Mail:  ${WP_ADMIN_EMAIL}

── Datenbank ─────────────────────────────────
DB-Host:       ${DB_HOST}
DB-Name:       ${DST_DB_NAME}
DB-User:       ${DST_DB_USER}
DB-Pass:       ${DST_DB_PASS}

── Filebrowser ───────────────────────────────
FB-User:       ${FB_USER}
FB-Pass:       ${FB_PASS}

── SFTP ──────────────────────────────────────
SFTP-Host:     $(hostname -I | awk '{print $1}')
SFTP-Port:     22
SFTP-User:     ${DST_SYSTEM_USER}
SFTP-Pass:     ${SFTP_PASS}
SFTP-Pfad:     /site

── Server ────────────────────────────────────
Site-Pfad:     ${DST_PATH}
System-User:   ${DST_SYSTEM_USER}
Geklont von:   ${SRC_DOMAIN}
EOF
chmod 600 "${SITES_DIR}/${DST_DOMAIN}.txt"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Klon erstellt ✓                            ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Quelle:     ${BOLD}https://${SRC_DOMAIN}${NC}"
echo -e "  Ziel:       ${BOLD}https://${DST_DOMAIN}${NC}"
echo -e "  DB:         ${BOLD}${DST_DB_NAME}${NC}"
# Bewusst OHNE Passwörter (wie install-wp.sh): stdout landet in Scrollback, Logs und
# Session-Mitschnitten. Die Werte stehen nur in der Site-Datei (chmod 600) → 1Password.
echo -e "  FB-User:    ${BOLD}${FB_USER}${NC}"
echo -e "  SFTP-User:  ${BOLD}${DST_SYSTEM_USER}${NC}"
echo -e "  Passwörter: ${BOLD}${SITES_DIR}/${DST_DOMAIN}.txt${NC}"
echo ""
echo -e "${YELLOW}  → NPM Proxy-Host für https://${DST_DOMAIN} anlegen (→ Port 80).${NC}"
echo -e "${YELLOW}  → Admin-Passwort der Quell-Site gilt auch für den Klon.${NC}"
echo -e "${YELLOW}  → Site im Maintenance Mode — freischalten: sudo bash maintenance.sh${NC}"
echo ""
