#!/bin/bash
# Datenbank-Cleanup aller (oder einer) WordPress-Sites — ersetzt WP-Optimize
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen
#
# Macht pro Site:
#   - abgelaufene Transients löschen (wp transient delete --expired)
#   - Papierkorb + auto-draft Posts entfernen
#   - Spam- und Trash-Kommentare löschen
#   - wp db optimize (OPTIMIZE TABLE — Fragmentierung freigeben)
#
# WP_POST_REVISIONS=5 + EMPTY_TRASH_DAYS=7 (aus install-wp.sh) decken den Rest ab.
#
# Usage:
#   sudo bash db-cleanup.sh                      — alle Sites
#   sudo bash db-cleanup.sh <domain>             — nur eine Site
#   sudo bash db-cleanup.sh --quiet              — ohne Ausgabe (für Cron)
#   sudo bash db-cleanup.sh --quiet --notify     — + Slack-Alarm bei Fehler
#
# Cron (via setup-web.sh): sonntags 05:00, flock-protected

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash db-cleanup.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

SITES_DIR="/etc/wp-hosting/sites"
LOG="/var/log/wp-db-cleanup.log"

# ── Argumente ──────────────────────────────────────────────────────────────
QUIET=false; NOTIFY=false; ONLY_DOMAIN=""
for arg in "$@"; do
    case "$arg" in
        --quiet)  QUIET=true ;;
        --notify) NOTIFY=true ;;
        --*)      err "Unbekannte Option: $arg (--quiet, --notify)" ;;
        *)        ONLY_DOMAIN="$arg" ;;
    esac
done

say() { $QUIET || echo -e "$1"; }

$QUIET || { clear; echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress DB-Cleanup                       ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"; }

echo "[$(date '+%Y-%m-%d %H:%M')] DB-Cleanup gestartet${ONLY_DOMAIN:+ (nur ${ONLY_DOMAIN})}" >> "$LOG"

CLEANED=0; FAILED=0; SKIPPED=0

shopt -s nullglob
CRED_FILES=("${SITES_DIR}"/*.txt)
shopt -u nullglob

if [[ ${#CRED_FILES[@]} -eq 0 ]]; then
    say "$(warn 'Keine Sites installiert.')"
    echo "[$(date '+%Y-%m-%d %H:%M')] Keine Sites gefunden" >> "$LOG"
    exit 0
fi

for CRED_FILE in "${CRED_FILES[@]}"; do
    DOMAIN=$(basename "$CRED_FILE" .txt)
    [[ -n "$ONLY_DOMAIN" && "$DOMAIN" != "$ONLY_DOMAIN" ]] && continue
    SITE_PATH="/var/www/${DOMAIN}"
    if [[ ! -d "$SITE_PATH" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # wp-cli als Site-User, nie als root (Dateien im Webroot, DB-Zugang nur über die
    # wp-config.php der Site). cd ins Site-Verzeichnis: wp-cli spawnt Subprozesse via
    # proc_open mit geerbtem cwd, das der nologin-User sonst nicht betreten darf.
    SITE_USER=$(stat -c %U "$SITE_PATH")
    if [[ "$SITE_USER" == "root" ]]; then
        say "$(warn "${DOMAIN} — Webroot gehört root, übersprungen")"
        echo "[$(date '+%Y-%m-%d %H:%M')] UEBERSPRUNGEN (root-Webroot): ${DOMAIN}" >> "$LOG"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    WP="sudo -n -u ${SITE_USER} wp --path=${SITE_PATH}"
    say "${BLUE}── ${DOMAIN} ──${NC}"

    if cd "$SITE_PATH" && {
        # Abgelaufene Transients
        $WP transient delete --expired

        # Papierkorb-Posts + auto-draft entfernen
        TRASH_IDS=$($WP post list --post_status=trash --format=ids 2>/dev/null || true)
        [[ -n "$TRASH_IDS" ]] && $WP post delete $TRASH_IDS --force
        DRAFT_IDS=$($WP post list --post_status=auto-draft --format=ids 2>/dev/null || true)
        [[ -n "$DRAFT_IDS" ]] && $WP post delete $DRAFT_IDS --force

        # Spam- + Trash-Kommentare
        SPAM_IDS=$($WP comment list --status=spam --format=ids 2>/dev/null || true)
        [[ -n "$SPAM_IDS" ]] && $WP comment delete $SPAM_IDS --force
        CTRASH_IDS=$($WP comment list --status=trash --format=ids 2>/dev/null || true)
        [[ -n "$CTRASH_IDS" ]] && $WP comment delete $CTRASH_IDS --force

        # Action Scheduler aufräumen — wächst auf Woo-Shops stark (WooCommerce +
        # Google/Meta/TikTok/PFM laufen alle darüber). Nur wo der Befehl existiert.
        # Plain "clean" respektiert die AS-Retention (Default 30 Tage), --batches=0
        # = alle eligiblen Batches in einem Lauf.
        if $WP cli has-command 'action-scheduler clean' 2>/dev/null; then
            $WP action-scheduler clean --batch-size=500 --batches=0
        fi

        # Tabellen optimieren (OPTIMIZE TABLE) — nach AS-Cleanup, gibt Platz frei
        $WP db optimize
    } >>"$LOG" 2>&1; then
        say "$(log "${DOMAIN} bereinigt")"
        echo "[$(date '+%Y-%m-%d %H:%M')] OK: ${DOMAIN}" >> "$LOG"
        CLEANED=$((CLEANED + 1))
    else
        say "$(warn "${DOMAIN} — Fehler beim Cleanup (siehe ${LOG})")"
        echo "[$(date '+%Y-%m-%d %H:%M')] FEHLER: ${DOMAIN}" >> "$LOG"
        FAILED=$((FAILED + 1))
    fi
done

MSG="DB-Cleanup: ${CLEANED} OK, ${FAILED} Fehler${SKIPPED:+, ${SKIPPED} übersprungen}"
echo "[$(date '+%Y-%m-%d %H:%M')] ${MSG}" >> "$LOG"

$QUIET || { echo ""; echo -e "${BOLD}${MSG}${NC}"; echo -e "Log: ${LOG}"; }

# Slack-Alarm nur bei Fehler
[[ -r /usr/local/lib/wp-hosting-notify.sh ]] && . /usr/local/lib/wp-hosting-notify.sh
if $NOTIFY && [[ $FAILED -gt 0 ]] && command -v notify >/dev/null 2>&1; then
    notify "DB-Cleanup mit Fehlern" "${MSG}"
fi

[[ $FAILED -gt 0 ]] && exit 1 || exit 0
