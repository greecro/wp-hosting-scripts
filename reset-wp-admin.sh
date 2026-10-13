#!/bin/bash
# Setzt das WordPress-Admin-Passwort einer Site zurück
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash reset-wp-admin.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Admin-Passwort zurücksetzen      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Site auswählen ────────────────────────────────────────────────────────
SITES_DIR="/etc/wp-hosting/sites"
[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && err "Keine installierten Sites gefunden."

echo "Installierte Sites:"
for f in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$f" .txt)
    USER=$(grep "^Admin-User:" "$f" 2>/dev/null | awk '{print $2}' || echo "?")
    echo "  - ${DOMAIN}  (Admin: ${USER})"
done
echo ""

read -rp "Domain: " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
CRED_FILE="${SITES_DIR}/${DOMAIN}.txt"
[[ ! -f "$CRED_FILE" ]] && err "Site '${DOMAIN}' nicht gefunden."

SITE_PATH="/var/www/${DOMAIN}"
[[ ! -d "$SITE_PATH" ]] && err "Site-Verzeichnis nicht gefunden: ${SITE_PATH}"

# Aktuellen Admin-User lesen
CURRENT_USER=$(grep "^Admin-User:" "$CRED_FILE" 2>/dev/null | awk '{print $2}' || echo "")

echo ""
echo "  Site:         ${BOLD}${DOMAIN}${NC}"
echo "  Admin-User:   ${BOLD}${CURRENT_USER:-unbekannt}${NC}"
echo ""

# Alle WP-User anzeigen
info "WordPress-Benutzer dieser Site:"
wp user list --path="$SITE_PATH" --allow-root --fields=ID,user_login,user_email,roles 2>/dev/null || true
echo ""

read -rp "Benutzername zum Zurücksetzen [${CURRENT_USER}]: " TARGET_USER
TARGET_USER=${TARGET_USER:-$CURRENT_USER}
[[ -z "$TARGET_USER" ]] && err "Kein Benutzername angegeben."

echo ""
echo "  1) Neues Passwort automatisch generieren"
echo "  2) Eigenes Passwort eingeben"
echo ""
read -rp "Auswahl [1/2]: " pass_choice

case "$pass_choice" in
    1)
        NEW_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 28) || true
        ;;
    2)
        read -rsp "Neues Passwort (mind. 12 Zeichen): " NEW_PASS; echo ""
        [[ ${#NEW_PASS} -lt 12 ]] && err "Passwort zu kurz (mind. 12 Zeichen)."
        ;;
    *) err "Ungültige Auswahl." ;;
esac

# Passwort zurücksetzen
# Passwort per stdin (--prompt=user_pass), nicht als argv; stdout weg, weil wp-cli bei
# --prompt die zusammengesetzte Kommandozeile samt Passwort druckt.
printf '%s\n' "$NEW_PASS" | wp user update "$TARGET_USER" --prompt=user_pass --quiet \
    --path="$SITE_PATH" --allow-root >/dev/null
log "Passwort zurückgesetzt für: ${TARGET_USER}"

# Alle Sessions dieses Users invalidieren (Sicherheit)
wp user session destroy "$TARGET_USER" --all \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Alle aktiven Sessions beendet"

# Credentials-Datei aktualisieren
# Zeile per Bash ersetzen — bei sed stünde das Passwort in der argv (Prozessliste).
_tmp=$(mktemp "${CRED_FILE}.XXXXXX"); _n=0
while IFS= read -r _l || [[ -n "$_l" ]]; do
    case "$_l" in
        "Admin-Pass:"*) printf 'Admin-Pass:    %s\n' "$NEW_PASS"; _n=$((_n + 1)) ;;
        *)              printf '%s\n' "$_l" ;;
    esac
done < "$CRED_FILE" > "$_tmp"
[[ $_n -eq 1 ]] || { rm -f "$_tmp"; err "Admin-Pass-Zeile ${_n}x in ${CRED_FILE} gefunden (erwartet 1) — Passwort ist in WP gesetzt, Datei von Hand nachziehen"; }
chmod 600 "$_tmp"; mv "$_tmp" "$CRED_FILE"
log "Credentials-Datei aktualisiert"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Passwort zurückgesetzt ✓                   ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Site:       ${BOLD}https://${DOMAIN}${NC}"
echo -e "  WP-Admin:   ${BOLD}https://${DOMAIN}/wp-admin${NC}"
echo -e "  Benutzer:   ${BOLD}${TARGET_USER}${NC}"
echo -e "  Passwort:   ${BOLD}in ${CRED_FILE}${NC} (nicht im Terminal — Scrollback/Mitschnitt)"
echo ""
echo -e "${YELLOW}  → Passwort aus ${CRED_FILE} nach 1Password übernehmen.${NC}"
echo ""
