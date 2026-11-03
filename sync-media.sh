#!/bin/bash
# Holt Logo/Favicon einer Site aus dem R2-Bucket "media" (Unterordner = Domain)
# und setzt sie in WordPress (Blocksy-Logo als Theme-Mod custom_logo, Favicon als
# site_icon). Gezielter Pull nur des eigenen Domain-Unterordners — kein Full-Mirror
# wie sync-plugins.sh, da Medien pro Site privat sind.
#
# Voraussetzung: setup-web.sh wurde mit MEDIA_BUCKET ausgeführt, als root ausführen
#
# Usage:
#   sudo bash sync-media.sh --domain <domain> [--force]
#
# Dateien im Bucket unter media/<domain>/ (Markenpaket, erster Treffer gewinnt):
#   Logo:    logo.png, <marke>-logo-color.png, logo.svg, <marke>-logo-color.svg
#   Favicon: favicon.png, <marke>-icon-1024.png bzw. icon-1024.png, icon-512.png
# PNG vor SVG: Ein SVG-Anhang hat in WordPress keine Bildmaße. Beide sind optional,
# importiert wird, was vorhanden ist.
# Idempotent: Sind custom_logo bzw. site_icon schon gesetzt, bleibt die Site unverändert
# (kein zweiter Anhang). --force importiert trotzdem neu.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash sync-media.sh --domain <domain>"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v rclone &>/dev/null || err "rclone nicht installiert."

source /etc/wp-hosting/config

[[ -z "${RCLONE_REMOTE:-}" ]] && err "RCLONE_REMOTE nicht konfiguriert."
if [[ -z "${MEDIA_BUCKET:-}" ]]; then
    warn "MEDIA_BUCKET nicht konfiguriert in /etc/wp-hosting/config — übersprungen."
    exit 0
fi

DOMAIN=""; FORCE="-"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --force)  FORCE="force"; shift ;;
        --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unbekannte Option: $1 (--domain, --force)" ;;
    esac
done
[[ -z "$DOMAIN" ]] && err "--domain fehlt."

CRED_FILE="/etc/wp-hosting/sites/${DOMAIN}.txt"
[[ -f "$CRED_FILE" ]] || err "Site '${DOMAIN}' nicht gefunden (${CRED_FILE})."
SITE_PATH="/var/www/${DOMAIN}"
[[ -d "$SITE_PATH" ]] || err "Site-Verzeichnis nicht gefunden: ${SITE_PATH}"

SYSTEM_USER=$(sed -nE 's/^System-User:[[:space:]]*//p' "$CRED_FILE" | head -1)
[[ -n "$SYSTEM_USER" ]] || err "System-User nicht in ${CRED_FILE} ermittelbar."
id "$SYSTEM_USER" &>/dev/null || err "Systemuser '${SYSTEM_USER}' existiert nicht."

IMPORT_PHP="/usr/local/lib/wp-hosting/media-import.php"
[[ -f "$IMPORT_PHP" ]] || err "media-import.php fehlt (${IMPORT_PHP}) — setup-web.sh erneut ausführen."

LOCAL_DIR="/etc/wp-hosting/media/${DOMAIN}"
mkdir -p "$LOCAL_DIR"

info "Sync ${RCLONE_REMOTE}:${MEDIA_BUCKET}/${DOMAIN}/ → ${LOCAL_DIR}/"
if ! rclone copy "${RCLONE_REMOTE}:${MEDIA_BUCKET}/${DOMAIN}/" "$LOCAL_DIR/" \
        --include "logo.png" --include "logo.svg" --include "*-logo-color.png" --include "*-logo-color.svg" \
        --include "favicon.png" --include "*icon-1024.png" --include "icon-512.png" 2>&1; then
    warn "Sync fehlgeschlagen — Bucket/Ordner erreichbar?"
    exit 1
fi

# Erster vorhandener Kandidat in Reihenfolge der Muster (Globs ohne Treffer fallen weg).
first_match() {
    local pat f
    shopt -s nullglob
    for pat in "$@"; do
        for f in "$LOCAL_DIR"/$pat; do
            [[ -f "$f" ]] && { shopt -u nullglob; echo "$f"; return 0; }
        done
    done
    shopt -u nullglob
    return 0
}
LOGO=$(first_match "logo.png" "*-logo-color.png" "logo.svg" "*-logo-color.svg")
FAVICON=$(first_match "favicon.png" "*icon-1024.png" "icon-512.png")

if [[ -z "$LOGO" && -z "$FAVICON" ]]; then
    warn "Weder Logo noch Favicon in media/${DOMAIN}/ gefunden — nichts zu tun."
    exit 0
fi
info "Logo: $([[ -n "$LOGO" ]] && basename "$LOGO" || echo —) · Favicon: $([[ -n "$FAVICON" ]] && basename "$FAVICON" || echo —)"

# Site-User braucht Lesezugriff auf die gesyncten Dateien (eval-file läuft als er).
chown -R "${SYSTEM_USER}:${SYSTEM_USER}" "$LOCAL_DIR"

RESULT=$(sudo -u "$SYSTEM_USER" wp --path="$SITE_PATH" eval-file "$IMPORT_PHP" \
    "${LOGO:--}" "${FAVICON:--}" "$FORCE" 2>&1) || { warn "Import fehlgeschlagen:"; echo "$RESULT"; exit 1; }

echo "$RESULT"
grep -q '^logo=ok'    <<<"$RESULT" && log "Logo gesetzt (custom_logo)"
grep -q '^logo=fail'  <<<"$RESULT" && warn "Logo-Import fehlgeschlagen"
grep -q '^favicon=ok' <<<"$RESULT" && log "Favicon gesetzt (site_icon)"
grep -q '^favicon=fail' <<<"$RESULT" && warn "Favicon-Import fehlgeschlagen"
grep -q '=skip'       <<<"$RESULT" && info "Bereits gesetzt, unverändert (neu importieren: --force)"
# Letztes grep ohne Treffer darf nicht zum Exit-Code des Scripts werden
exit 0
