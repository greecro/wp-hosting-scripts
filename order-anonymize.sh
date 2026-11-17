#!/bin/bash
# Bestellungen nach Ablauf der Aufbewahrungsfrist anonymisieren (Jahreslauf).
#
# Bezugsjahr = Jahr des jüngsten Datums aus Bestellung, Zahlung, Abschluss, Erstattung und Rechnung.
# Fällig, wenn Bezugsjahr <= laufendes Jahr minus 9. --max-year kann die Grenze nur senken.
# Anonymisiert wird über WooCommerce (WC_Privacy_Erasers), dazu Kundennotiz, Zahler-E-Mail, Matomo- und
# Attribution-Kennungen und die Inhaberfelder der FSLM-Lizenzschlüssel dieser Bestellungen.
#
# Ohne --apply wird nur gezählt (Trockenlauf, Zählung je Bezugsjahr). Der Echtlauf verlangt --max-year.
# Ausgabe und Protokoll (/var/log/wp-order-retention.log) enthalten nur Zahlen, nie Personendaten.
#
# Nicht angefasst werden: bereits anonymisierte Bestellungen, Bestellungen mit der Meta wph_retention_hold,
# Bestellungen mit Rechnungsnummer (PDF Invoices) und die IDs aus der Haltedatei
#   /etc/wp-hosting/retention-hold-<domain>.txt   (eine Bestell-ID je Zeile, # Kommentar erlaubt)
# für Prüfung, Einspruch, Rechtsstreit, Chargeback. Eine nicht lesbare Zeile bricht den Lauf der Site ab.
#
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen
#
# Usage:
#   sudo bash order-anonymize.sh                                   — Trockenlauf über alle WooCommerce-Sites
#   sudo bash order-anonymize.sh --domain <domain> --max-year 2015 — Trockenlauf, Lauf nur bis Bezugsjahr 2015
#   sudo bash order-anonymize.sh --domain <domain> --max-year 2015 --apply   — wirklich anonymisieren
#
# Optionen:
#   --max-year JJJJ|auto  obere Grenze des Bezugsjahres (auto = laufendes Jahr minus 9)
#   --only-ids a,b        nur diese Bestell-IDs (für Tests)
#   --basend              vor jeder Anonymisierung die Action wph_order_retention_anonymize( $order_id ) auslösen
#                         (Standard aus; BaseSend kann sich später daran hängen, noch ohne Aufruf)
#   --quiet               keine Ausgabe
#   --notify              Slack-Meldung bei Fehlern
#
# Exit-Code = Anzahl der Sites mit Fehler.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
err() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash order-anonymize.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

DOMAIN=""; APPLY=false; YEAR="-"; ONLY="-"; BASEND="-"; QUIET=false; NOTIFY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="${2:-}"; shift 2 ;;
        --all)      DOMAIN=""; shift ;;
        --apply)    APPLY=true; shift ;;
        --max-year) YEAR="${2:-}"; shift 2 ;;
        --only-ids) ONLY="${2:-}"; shift 2 ;;
        --basend)   BASEND="basend"; shift ;;
        --quiet)    QUIET=true; shift ;;
        --notify)   NOTIFY=true; shift ;;
        --help|-h)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unbekannte Option: $1 (--domain, --max-year, --apply, --only-ids, --basend, --quiet, --notify)" ;;
    esac
done
[[ "$YEAR" == "-" || "$YEAR" == "auto" || "$YEAR" =~ ^[0-9]{4}$ ]] || err "--max-year braucht eine vierstellige Jahreszahl oder auto."
[[ "$ONLY" == "-" || "$ONLY" =~ ^[0-9]+(,[0-9]+)*$ ]] || err "--only-ids braucht eine Komma-Liste von Bestell-IDs."
if $APPLY && [[ "$YEAR" == "-" ]]; then
    err "Der Echtlauf verlangt --max-year <JJJJ|auto> (erster Lauf: nur bis zu einem bewusst gewählten Jahr)."
fi

PHP="/usr/local/lib/wp-hosting/order-anonymize.php"
[[ -f "$PHP" ]] || err "order-anonymize.php fehlt (${PHP}) — setup-web.sh erneut ausführen."
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

    if ! ACTIVE=$("${WPC[@]}" plugin list --status=active --field=name 2>/dev/null); then
        say "${YELLOW}[!]${NC} ${D}: wp-cli lieferte einen Fehler"; FAILED=$((FAILED + 1)); continue
    fi
    if ! grep -qx woocommerce <<<"$ACTIVE"; then
        say "${D}: übersprungen (kein WooCommerce)"; SKIPPED=$((SKIPPED + 1)); continue
    fi

    # Haltedatei lesen. Ein Tippfehler darf nie dazu führen, dass eine gehaltene Bestellung anonymisiert wird.
    HOLD="-"; HOLD_FILE="/etc/wp-hosting/retention-hold-${D}.txt"
    if [[ -f "$HOLD_FILE" ]]; then
        BAD=$(grep -c -v -E '^[[:space:]]*(#.*)?$|^[[:space:]]*[0-9]+([[:space:]#].*)?$' "$HOLD_FILE" || true)
        if [[ "$BAD" != "0" ]]; then
            say "${YELLOW}[!]${NC} ${D}: ${BAD} nicht lesbare Zeile(n) in ${HOLD_FILE} — Site übersprungen"
            echo "[$(date '+%Y-%m-%d %H:%M')] order-anonymize ${D}: Haltedatei hat ${BAD} nicht lesbare Zeile(n), Site übersprungen" >> "$LOG"
            FAILED=$((FAILED + 1)); continue
        fi
        HOLD=$(sed -nE 's/^[[:space:]]*([0-9]+)([[:space:]#].*)?$/\1/p' "$HOLD_FILE" | paste -sd, -)
        [[ -n "$HOLD" ]] || HOLD="-"
    fi

    RC=0
    OUT=$("${WPC[@]}" eval-file "$PHP" "$MODE" "$YEAR" 200 "$ONLY" "$HOLD" "$BASEND" 2>&1) || RC=$?

    {
        echo "[$(date '+%Y-%m-%d %H:%M')] order-anonymize ${D} (${LABEL}) rc=${RC}"
        sed 's/^/    /' <<<"$OUT"
    } >> "$LOG"

    say "${GREEN}== ${D} (${LABEL})${NC}"
    say "$(sed 's/^/  /' <<<"$OUT")"
    if [[ $RC -eq 0 ]]; then OK=$((OK + 1)); else FAILED=$((FAILED + 1)); say "${YELLOW}[!]${NC} ${D}: Fehler (Exit ${RC}), siehe ${LOG}"; fi
done

[[ -n "$DOMAIN" && $FOUND -eq 0 ]] && err "Site '${DOMAIN}' nicht gefunden."

MSG="order-anonymize (${LABEL}): ${OK} OK, ${FAILED} Fehler, ${SKIPPED} übersprungen"
echo "[$(date '+%Y-%m-%d %H:%M')] ${MSG}" >> "$LOG"
say "$MSG"

[[ -r /usr/local/lib/wp-hosting-notify.sh ]] && . /usr/local/lib/wp-hosting-notify.sh
if $NOTIFY && [[ $FAILED -gt 0 ]] && command -v notify >/dev/null 2>&1; then
    notify "Bestell-Anonymisierung mit Fehlern" "${MSG} — Details: ${LOG}"
fi

exit "$FAILED"
