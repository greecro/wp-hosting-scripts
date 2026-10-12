#!/bin/bash
# Aktualisiert WordPress Core, Plugins und Themes aller installierten Sites
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash update-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Bulk-Update                      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

SITES_DIR="/etc/wp-hosting/sites"
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    err "Keine installierten Sites gefunden."
fi

# Auswahl: alle oder einzelne Site
echo "Was soll aktualisiert werden?"
echo "  1) Alle Sites"
echo "  2) Einzelne Site auswählen"
echo ""
read -rp "Auswahl [1/2]: " update_choice

SITES_TO_UPDATE=()
case "$update_choice" in
    1)
        for f in "${SITES_DIR}"/*.txt; do
            SITES_TO_UPDATE+=("$(basename "$f" .txt)")
        done
        ;;
    2)
        echo ""
        echo "Installierte Sites:"
        for f in "${SITES_DIR}"/*.txt; do
            echo "  - $(basename "$f" .txt)"
        done
        echo ""
        read -rp "Domain: " SINGLE_DOMAIN
        SINGLE_DOMAIN=$(echo "$SINGLE_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
        [[ ! -f "${SITES_DIR}/${SINGLE_DOMAIN}.txt" ]] && err "Site '${SINGLE_DOMAIN}' nicht gefunden."
        SITES_TO_UPDATE=("$SINGLE_DOMAIN")
        ;;
    *) err "Ungültige Auswahl." ;;
esac

echo ""
echo "Was soll aktualisiert werden?"
echo "  1) Alles (Core + Plugins + Themes)"
echo "  2) Nur Plugins"
echo "  3) Nur Themes"
echo "  4) Nur WordPress Core"
echo ""
read -rp "Auswahl [1-4]: " scope_choice

UPDATE_CORE=false; UPDATE_PLUGINS=false; UPDATE_THEMES=false
case "$scope_choice" in
    1) UPDATE_CORE=true; UPDATE_PLUGINS=true; UPDATE_THEMES=true ;;
    2) UPDATE_PLUGINS=true ;;
    3) UPDATE_THEMES=true ;;
    4) UPDATE_CORE=true ;;
    *) err "Ungültige Auswahl." ;;
esac

echo ""
info "${#SITES_TO_UPDATE[@]} Site(s) werden aktualisiert..."
echo ""

# Ergebnis-Tracking
UPDATED=(); FAILED=(); SKIPPED=()

for DOMAIN in "${SITES_TO_UPDATE[@]}"; do
    SITE_PATH="/var/www/${DOMAIN}"
    # Systemuser aus der Cred-Datei (install-wp benennt ihn wp_<12-alnum>_<sha256-8>);
    # die frühere Ableitung aus der Domain ergab einen nicht existierenden Namen, der
    # chown auf das Wartungs-Flag lief dadurch ins Leere.
    SYSTEM_USER=$(sed -nE 's/^System-User:[[:space:]]*//p' "${SITES_DIR}/${DOMAIN}.txt" 2>/dev/null | head -1)
    if [[ -z "$SYSTEM_USER" ]]; then
        DOMAIN_SAFE="$(printf '%s' "$DOMAIN" | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-8)"
        SYSTEM_USER="wp_${DOMAIN_SAFE}"
    fi

    if [[ ! -d "$SITE_PATH" ]]; then
        warn "Verzeichnis nicht gefunden: ${SITE_PATH} — übersprungen"
        SKIPPED+=("$DOMAIN")
        continue
    fi

    echo -e "${BLUE}──────────────────────────────────────────────${NC}"
    info "Aktualisiere: ${BOLD}${DOMAIN}${NC}"

    # Lock je Domain, gemeinsam mit dashy-wp-update (Dashy): nie zwei Updates derselben Site zugleich
    mkdir -p -m 700 /run/lock/wp-hosting
    exec 9>"/run/lock/wp-hosting/${DOMAIN}.lock"
    if ! flock -w 300 9; then
        warn "  Site ist gesperrt (anderes Update läuft) — übersprungen"
        SKIPPED+=("$DOMAIN"); exec 9>&-
        continue
    fi

    WP_CMD="wp --path=${SITE_PATH} --allow-root"
    SITE_OK=true

    # Maintenance Mode aktivieren (custom flag — zeigt eigene Seite)
    MAINT_FLAG="${SITE_PATH}/wp-content/.maintenance-active"
    touch "$MAINT_FLAG" && chown "${SYSTEM_USER}:www-data" "$MAINT_FLAG" 2>/dev/null || true

    # ── Pre-Update-Snapshot ──────────────────────────────────────────────
    # Schneller Snapshot vor jedem Update — bei Fehler verfügbar zum Rollback.
    # Nach erfolgreichem Update automatisch entfernt (max. 5 letzte werden behalten).
    PRE_DIR="/var/backups/wp-pre-update"
    mkdir -p "$PRE_DIR"
    PRE_TS=$(date +%Y%m%d_%H%M%S)
    PRE_FILES="${PRE_DIR}/${DOMAIN}_${PRE_TS}.tar.gz"
    PRE_DB="${PRE_DIR}/${DOMAIN}_${PRE_TS}.sql.gz"
    DB_NAME=$(grep "^DB-Name:" "/etc/wp-hosting/sites/${DOMAIN}.txt" 2>/dev/null | awk '{print $2}' || echo "")
    DB_USER=$(grep "^DB-User:" "/etc/wp-hosting/sites/${DOMAIN}.txt" 2>/dev/null | awk '{print $2}' || echo "")
    DB_PASS=$(grep "^DB-Pass:" "/etc/wp-hosting/sites/${DOMAIN}.txt" 2>/dev/null | awk '{print $2}' || echo "")

    info "  Pre-Update-Snapshot..."
    tar -czf "$PRE_FILES" --exclude="wp-content/cache" --exclude="wp-content/upgrade" \
        -C "$SITE_PATH" wp-content 2>/dev/null || warn "  Files-Snapshot fehlgeschlagen"
    if [[ -n "$DB_NAME" ]]; then
        MYSQL_PWD="$DB_PASS" mysqldump -h "${DB_HOST:-localhost}" -u "$DB_USER" \
            --single-transaction --quick "$DB_NAME" 2>/dev/null \
            | gzip > "$PRE_DB" || warn "  DB-Snapshot fehlgeschlagen"
    fi

    # Retention: nur die 5 letzten Snapshots pro Domain behalten
    ls -t "${PRE_DIR}/${DOMAIN}_"*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -t "${PRE_DIR}/${DOMAIN}_"*.sql.gz 2>/dev/null | tail -n +6 | xargs -r rm -f

    if $UPDATE_CORE; then
        if $WP_CMD core update 2>&1 | grep -qE "Success|already"; then
            log "  Core aktualisiert"
        else
            warn "  Core-Update fehlgeschlagen"
            SITE_OK=false
        fi
    fi

    PLUGIN_COUNT=0
    THEME_COUNT=0
    if $UPDATE_PLUGINS; then
        # Exit-Code von wp erfassen (nicht nur "Updated"-Zeilen zählen)
        PLUGIN_OUT=$($WP_CMD plugin update --all 2>&1) && PLUGIN_RC=0 || PLUGIN_RC=$?
        PLUGIN_COUNT=$(echo "$PLUGIN_OUT" | grep -c "Updated" || true)
        [[ ${PLUGIN_RC:-0} -ne 0 ]] && { warn "  Plugin-Update meldete Fehler (rc=${PLUGIN_RC})"; SITE_OK=false; }
        log "  Plugins: ${PLUGIN_COUNT} aktualisiert"
    fi

    if $UPDATE_THEMES; then
        THEME_OUT=$($WP_CMD theme update --all 2>&1) && THEME_RC=0 || THEME_RC=$?
        THEME_COUNT=$(echo "$THEME_OUT" | grep -c "Updated" || true)
        [[ ${THEME_RC:-0} -ne 0 ]] && { warn "  Theme-Update meldete Fehler (rc=${THEME_RC})"; SITE_OK=false; }
        log "  Themes: ${THEME_COUNT} aktualisiert"
    fi

    # Pro-Site Detail in Logfile (für Cron-Auswertung)
    LOGFILE="/var/log/wp-update-detail.log"
    echo "[$(date '+%Y-%m-%d %H:%M')] ${DOMAIN}: core=$( $UPDATE_CORE && echo y || echo n) plugins=${PLUGIN_COUNT} themes=${THEME_COUNT} ok=${SITE_OK}" >> "$LOGFILE" 2>/dev/null || true

    # Datenbank-Migration falls nötig
    $WP_CMD core update-db 2>&1 | grep -q "Success" && log "  DB-Schema aktualisiert" || true

    # Caches leeren
    $WP_CMD cache flush 2>/dev/null || true
    $WP_CMD transient delete --all 2>/dev/null || true
    log "  Cache geleert"

    # Maintenance Mode deaktivieren
    rm -f "${SITE_PATH}/wp-content/.maintenance-active" 2>/dev/null || true

    if $SITE_OK; then
        UPDATED+=("$DOMAIN")
    else
        FAILED+=("$DOMAIN")
    fi
    exec 9>&-
done

# ── FastCGI Cache leeren (WooCommerce-VMs) ────────────────────────────────
if [[ -d /var/cache/nginx/wp ]]; then
    rm -rf /var/cache/nginx/wp/*
    log "FastCGI-Cache geleert"
fi

# ── OPcache leeren ────────────────────────────────────────────────────────
# PHP-FPM neu laden → alle kompilierten Bytecode-Dateien verworfen
# Verhindert, dass veraltete OPcache-Einträge nach Core-Updates aktiv bleiben
systemctl reload php8.3-fpm
log "OPcache geleert (PHP-FPM neu geladen)"

# ── Webhook-Benachrichtigung ──────────────────────────────────────────────
WEBHOOK_URL="${WEBHOOK_URL:-}"
[[ -f /etc/wp-hosting/config ]] && source /etc/wp-hosting/config 2>/dev/null || true

if [[ -n "${WEBHOOK_URL:-}" ]]; then
    MSG="${#UPDATED[@]} Site(s) aktualisiert"
    [[ ${#FAILED[@]} -gt 0 ]] && MSG="${MSG}, ${#FAILED[@]} Fehler: ${FAILED[*]}"
    STATUS=$( [[ ${#FAILED[@]} -eq 0 ]] && echo "up" || echo "down" )
    curl -fsS -G \
        --data-urlencode "msg=${MSG}" \
        "${WEBHOOK_URL}?status=${STATUS}" \
        -o /dev/null 2>/dev/null && log "Webhook-Benachrichtigung gesendet" || warn "Webhook fehlgeschlagen"
fi

# ── Zusammenfassung ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Update abgeschlossen ✓                     ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Erfolgreich:  ${BOLD}${#UPDATED[@]}${NC} Site(s)"
[[ ${#SKIPPED[@]} -gt 0 ]] && echo -e "  Übersprungen: ${BOLD}${#SKIPPED[@]}${NC} Site(s)"
[[ ${#FAILED[@]}  -gt 0 ]] && echo -e "${RED}  Fehler:       ${BOLD}${#FAILED[@]}${NC}${RED} Site(s): ${FAILED[*]}${NC}"
echo ""

# Exit-Code für Cron/Cronicle: non-zero, wenn eine Site fehlschlug
[[ ${#FAILED[@]} -eq 0 ]] && exit 0 || exit 1
