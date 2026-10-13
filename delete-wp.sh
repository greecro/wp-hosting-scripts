#!/bin/bash
# Entfernt eine WordPress-Site vollständig (Nginx, PHP-FPM, DB, Dateien, User)
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash delete-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

source /etc/wp-hosting/config

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site entfernen                   ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# Installierte Sites auflisten
SITES_DIR="/etc/wp-hosting/sites"
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    err "Keine installierten Sites gefunden."
fi

echo "Installierte Sites:"
for f in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$f" .txt)
    TYPE=$(grep "^Typ:" "$f" 2>/dev/null | awk '{print $2}' || echo "unbekannt")
    echo "  - ${DOMAIN} (${TYPE})"
done
echo ""

read -rp "Domain der zu löschenden Site: " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."

CRED_FILE="${SITES_DIR}/${DOMAIN}.txt"
[[ ! -f "$CRED_FILE" ]] && err "Site '${DOMAIN}' nicht gefunden."

# Daten aus Credentials-Datei lesen
DB_NAME=$(grep "^DB-Name:" "$CRED_FILE" | awk '{print $2}')
DB_USER=$(grep "^DB-User:" "$CRED_FILE" | awk '{print $2}')
# Muss identisch zu install-wp.sh gebildet werden (deterministisch), damit der richtige System-User getroffen wird
DOMAIN_SAFE="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-8)"
SYSTEM_USER="wp_${DOMAIN_SAFE}"
SITE_PATH="/var/www/${DOMAIN}"

echo ""
echo -e "${RED}${BOLD}ACHTUNG — folgende Daten werden unwiderruflich gelöscht:${NC}"
echo -e "  Site-Dateien:  ${BOLD}${SITE_PATH}${NC}"
echo -e "  Datenbank:     ${BOLD}${DB_NAME}${NC}"
echo -e "  DB-User:       ${BOLD}${DB_USER}${NC}"
echo -e "  System-User:   ${BOLD}${SYSTEM_USER}${NC}"
echo -e "  Nginx-Vhost:   ${BOLD}/etc/nginx/sites-available/${DOMAIN}${NC}"
echo -e "  PHP-FPM-Pool:  ${BOLD}/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf${NC}"
echo ""
read -rp "Domain zur Bestätigung nochmal eingeben: " CONFIRM_DOMAIN
[[ "$CONFIRM_DOMAIN" != "$DOMAIN" ]] && err "Eingabe stimmt nicht überein — abgebrochen."

# ── Nginx ─────────────────────────────────────────────────────────────────
rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
rm -f "/etc/nginx/sites-available/${DOMAIN}"
nginx -t && systemctl reload nginx
log "Nginx-Vhost entfernt"

# ── PHP-FPM Pool ──────────────────────────────────────────────────────────
rm -f "/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf"
systemctl reload php8.3-fpm
log "PHP-FPM Pool entfernt"

# ── Datenbank ─────────────────────────────────────────────────────────────
if [[ -n "$DB_NAME" ]] && [[ -n "$DB_USER" ]]; then
    WEB_VM_IP=$(hostname -I | awk '{print $1}')
    MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" <<SQL 2>/dev/null || warn "DB-Bereinigung teilweise fehlgeschlagen"
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'${WEB_VM_IP}';
FLUSH PRIVILEGES;
SQL
    log "Datenbank und DB-User entfernt"
else
    warn "Datenbankdaten nicht gefunden — manuell prüfen"
fi

# ── Site-Dateien ──────────────────────────────────────────────────────────
rm -rf "$SITE_PATH"
log "Site-Verzeichnis entfernt: ${SITE_PATH}"

# ── Filebrowser User entfernen ────────────────────────────────────────────
FB_DB="/etc/filebrowser/database.db"
FB_USER="${DOMAIN_SAFE:0:32}"
if [[ -f "$FB_DB" ]] && command -v filebrowser &>/dev/null; then
    # Der laufende Dienst haelt die Bolt-DB exklusiv — ohne Stopp scheitert das Entfernen
    # mit "Error: timeout" und der User bliebe als Leiche mit Zugriff zurueck.
    _fb_was_active=false
    if systemctl is-active --quiet filebrowser 2>/dev/null; then _fb_was_active=true; fi
    $_fb_was_active && { systemctl stop filebrowser 2>/dev/null || true; }
    if filebrowser users rm "$FB_USER" --database "$FB_DB" >/dev/null 2>&1; then
        log "Filebrowser User entfernt: ${FB_USER}"
    else
        warn "Filebrowser User ${FB_USER} konnte nicht entfernt werden — bitte manuell prüfen."
    fi
    $_fb_was_active && { systemctl start filebrowser 2>/dev/null || true; }
fi

# ── SFTP Chroot aufräumen ─────────────────────────────────────────────────
SFTP_CHROOT="/var/sftp/${SYSTEM_USER}"
if [[ -d "$SFTP_CHROOT" ]]; then
    umount "${SFTP_CHROOT}/site" 2>/dev/null || true
    # fstab-Eintrag entfernen
    sed -i "\|${SFTP_CHROOT}/site|d" /etc/fstab
    rm -rf "$SFTP_CHROOT"
    log "SFTP Chroot entfernt: ${SFTP_CHROOT}"
fi

# ── Systemuser ────────────────────────────────────────────────────────────
if id "$SYSTEM_USER" &>/dev/null; then
    userdel "$SYSTEM_USER" 2>/dev/null || true
    log "Systemuser entfernt: ${SYSTEM_USER}"
fi

# ── WP-Cron-Job ───────────────────────────────────────────────────────────
rm -f "/etc/cron.d/wpcron-${DOMAIN_SAFE}"
log "WP-Cron-Job entfernt"

# ── Log-Dateien entfernen ─────────────────────────────────────────────────
rm -f "/var/log/php/${DOMAIN}.error.log"
rm -f "/var/log/php/${DOMAIN}.slow.log"
rm -f "/var/log/nginx/${DOMAIN}.access.log"
rm -f "/var/log/nginx/${DOMAIN}.error.log"

# ── SSL-Monitor-State entfernen ───────────────────────────────────────────
rm -f "/var/lib/wp-hosting/ssl-state/${DOMAIN}"

# ── Credentials-Datei archivieren ─────────────────────────────────────────
mkdir -p /etc/wp-hosting/deleted
mv "$CRED_FILE" "/etc/wp-hosting/deleted/${DOMAIN}.$(date +%Y%m%d%H%M).txt"
log "Zugangsdaten archiviert: /etc/wp-hosting/deleted/"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Site entfernt ✓                            ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DOMAIN} wurde vollständig entfernt."
echo -e "${YELLOW}  → NPM Proxy-Host für ${DOMAIN} manuell löschen.${NC}"
echo ""
