#!/bin/bash
# IP-Adresse und Browserkennung in Bestellungen nach Fristablauf leeren (Standard: 120 Tage ab Bestelldatum,
# Chargeback-Fenster). Die Bestellung selbst bleibt unverändert, gelöscht wird nur die Kennung.
#
# Ohne --apply wird nur gezählt (Trockenlauf). Im Betrieb täglich per Cron mit --apply (setup-web.sh).
# Ausgabe und Protokoll (/var/log/wp-order-retention.log) enthalten nur Zahlen, nie Personendaten.
#
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen
#
# Usage:
#   sudo bash order-ip-purge.sh                    — Trockenlauf über alle WooCommerce-Sites
#   sudo bash order-ip-purge.sh --domain <domain>  — nur eine Site
#   sudo bash order-ip-purge.sh --apply            — wirklich leeren
#
# Optionen:
#   --days N         Frist in Tagen (Standard 120)
#   --only-ids a,b   nur diese Bestell-IDs (für Tests)
#   --quiet          keine Ausgabe (für Cron)
#   --notify         Slack-Meldung bei Fehlern
#
# Exit-Code = Anzahl der Sites mit Fehler.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
err() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash order-ip-purge.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

DOMAIN=""; APPLY=false; DAYS=120; ONLY="-"; QUIET=false; NOTIFY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="${2:-}"; shift 2 ;;
        --all)      DOMAIN=""; shift ;;
        --apply)    APPLY=true; shift ;;
        --days)     DAYS="${2:-}"; shift 2 ;;
        --only-ids) ONLY="${2:-}"; shift 2 ;;
        --quiet)    QUIET=true; shift ;;
        --notify)   NOTIFY=true; shift ;;
        --help|-h)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unbekannte Option: $1 (--domain, --apply, --days, --only-ids, --quiet, --notify)" ;;
    esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] || err "--days braucht eine Zahl."
[[ "$ONLY" == "-" || "$ONLY" =~ ^[0-9]+(,[0-9]+)*$ ]] || err "--only-ids braucht eine Komma-Liste von Bestell-IDs."

PHP="/usr/local/lib/wp-hosting/order-ip-purge.php"
[[ -f "$PHP" ]] || err "order-ip-purge.php fehlt (${PHP}) — setup-web.sh erneut ausführen."
SITES_DIR="/etc/wp-hosting/sites"
LOG="/var/log/wp-order-retention.log"
MODE=$($APPLY && echo apply || echo dry)
LABEL=$($APPLY && echo "Echtlauf" || echo "Trockenlauf")

say() { $QUIET || echo -e "$1"; }

shopt -s nullglob
CRED_FILES=("${SITES_DIR}"/*.txt)
shopt -u nullglob
[[ ${#CRED_FILES[@]} -eq 0 ]] && { say "${YELLOW}[!]${NC} Keine Sites installiert."; exit 0; }

OK=0; FAILED=0; SKIPPED=0; FOUND=0
for CRED_FILE in "${CRED_FILES[@]}"; do
    D=$(basename "$CRED_FILE" .txt)
    [[ -n "$DOMAIN" && "$D" != "$DOMAIN" ]] && continue
    FOUND=$((FOUND + 1))
    SITE_PATH="/var/www/${D}"
    if [[ ! -d "$SITE_PATH" ]]; then
        say "${YELLOW}[!]${NC} ${D}: Verzeichnis fehlt — übersprungen"; FAILED=$((FAILED + 1)); continue
    fi
    SYSTEM_USER=$(sed -nE '/^System-User:/{s/^System-User:[[:space:]]*//p;q}' "$CRED_FILE")
    if [[ -z "$SYSTEM_USER" ]] || ! id "$SYSTEM_USER" &>/dev/null; then
        say "${YELLOW}[!]${NC} ${D}: Systemuser nicht ermittelbar"; FAILED=$((FAILED + 1)); continue
    fi
    WPC=(sudo -u "$SYSTEM_USER" wp --path="$SITE_PATH")

    # WooCommerce aktiv? Ein wp-Fehler zählt als Fehler, nicht als "kein WooCommerce".
    if ! ACTIVE=$("${WPC[@]}" plugin list --status=active --field=name 2>/dev/null); then
        say "${YELLOW}[!]${NC} ${D}: wp-cli lieferte einen Fehler"; FAILED=$((FAILED + 1)); continue
    fi
    if ! grep -qx woocommerce <<<"$ACTIVE"; then
        say "${D}: übersprungen (kein WooCommerce)"; SKIPPED=$((SKIPPED + 1)); continue
    fi

    RC=0
    OUT=$("${WPC[@]}" eval-file "$PHP" "$MODE" "$DAYS" 500 "$ONLY" 2>&1) || RC=$?

    {
        echo "[$(date '+%Y-%m-%d %H:%M')] order-ip-purge ${D} (${LABEL}) rc=${RC}"
        sed 's/^/    /' <<<"$OUT"
    } >> "$LOG"

    say "${GREEN}== ${D} (${LABEL})${NC}"
    say "$(sed 's/^/  /' <<<"$OUT")"
    if [[ $RC -eq 0 ]]; then OK=$((OK + 1)); else FAILED=$((FAILED + 1)); say "${YELLOW}[!]${NC} ${D}: Fehler (Exit ${RC}), siehe ${LOG}"; fi
done

[[ -n "$DOMAIN" && $FOUND -eq 0 ]] && err "Site '${DOMAIN}' nicht gefunden."

MSG="order-ip-purge (${LABEL}): ${OK} OK, ${FAILED} Fehler, ${SKIPPED} übersprungen"
echo "[$(date '+%Y-%m-%d %H:%M')] ${MSG}" >> "$LOG"
say "$MSG"

[[ -r /usr/local/lib/wp-hosting-notify.sh ]] && . /usr/local/lib/wp-hosting-notify.sh
if $NOTIFY && [[ $FAILED -gt 0 ]] && command -v notify >/dev/null 2>&1; then
    notify "Bestell-IP-Löschung mit Fehlern" "${MSG} — Details: ${LOG}"
fi

exit "$FAILED"
