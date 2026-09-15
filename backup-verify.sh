#!/bin/bash
# Verifiziert Datei- und DB-Backups (Integrität, Entschlüsselbarkeit)
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash backup-verify.sh"

FILES_DIR="/var/backups/wp-files"
DB_DIR="/var/backups/mysql"
AGE_KEY="/etc/wp-hosting/backup-key.txt"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Flags parsen
QUIET=false
DEEP=false
for arg in "$@"; do
    case "$arg" in
        --quiet)  QUIET=true ;;
        --deep)   DEEP=true ;;
        --notify) ;; # später ausgewertet
    esac
done

# --deep: einmal pro Monat (am 1.) zusätzlich das ÄLTESTE Backup prüfen
# (testet ob Retention-Logic noch greift und alte Backups lesbar sind)
if [[ "$(date +%d)" == "01" ]] && ! $DEEP; then
    DEEP=true
    $QUIET || echo "Monatlich am 1.: Auch ältestes Backup wird geprüft (--deep)"
fi

if ! $QUIET; then
    clear 2>/dev/null || true
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Backup-Verifikation                        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
fi

OK=0
FAILED=0
FAILED_FILES=()

verify_file() {
    local f="$1"
    local kind="$2"   # "files" oder "db"

    if [[ "$f" == *.age ]]; then
        if [[ ! -f "$AGE_KEY" ]]; then
            # Privater Key liegt bewusst nicht auf dieser VM (zentral in 1Password,
            # keys/wp-hosting age Stack-Key) — nur der öffentliche Recipient ist hier.
            # Entschlüsselbarkeit wird zentral geprüft (verify-backups-central.sh).
            # Hier nur Existenz/Größe, damit ein fehlender Key keinen Fehlalarm wirft.
            [[ -s "$f" ]] || { FAILED_FILES+=("$f (leer)"); return 1; }
            return 0
        fi
        # Nur ein leichter Decrypt-Check: Header lesen
        age -d -i "$AGE_KEY" "$f" 2>/dev/null | head -c 1 >/dev/null || \
            { FAILED_FILES+=("$f (Entschlüsselung)"); return 1; }
    fi

    if [[ "$kind" == "files" ]]; then
        # tar.gz Integritätsprüfung (zlib-CRC + tar header)
        if [[ "$f" == *.age ]]; then
            age -d -i "$AGE_KEY" "$f" 2>/dev/null | tar -tzf - >/dev/null 2>&1 || \
                { FAILED_FILES+=("$f (tar-corrupt)"); return 1; }
        else
            tar -tzf "$f" >/dev/null 2>&1 || { FAILED_FILES+=("$f (tar-corrupt)"); return 1; }
        fi
    else
        # SQL-Dump: muss CREATE/INSERT enthalten
        local content
        # || true: head -c schließt die Pipe → zcat (dekomprimiert die ganze Datei)
        # bekommt SIGPIPE → Exit 141 unter set -o pipefail. Nur die 4 KB zählen.
        if [[ "$f" == *.age ]]; then
            content=$(age -d -i "$AGE_KEY" "$f" 2>/dev/null | zcat 2>/dev/null | head -c 4096) || true
        else
            content=$(zcat "$f" 2>/dev/null | head -c 4096) || true
        fi
        echo "$content" | grep -qE "^(CREATE|INSERT|--|/\*)" || \
            { FAILED_FILES+=("$f (kein SQL-Inhalt)"); return 1; }
    fi
    return 0
}

# Helper: jüngstes (und im --deep Modus zusätzlich ältestes) Backup pro Gruppe
collect_backups() {
    local dir="$1" pattern_re="$2"
    local -A first_seen last_seen
    while IFS= read -r f; do
        local key
        key=$(basename "$f" | sed -E "$pattern_re")
        [[ -z "${first_seen[$key]:-}" ]] && first_seen[$key]="$f"
        last_seen[$key]="$f"
    done < <(find "$dir" -type f \( -name '*.tar.gz' -o -name '*.tar.gz.age' -o -name '*.sql.gz' -o -name '*.sql.gz.age' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    # Jüngstes (first in -t order) + im DEEP-Modus auch ältestes
    for k in "${!first_seen[@]}"; do
        echo "${first_seen[$k]}"  # jüngstes
        if $DEEP && [[ "${first_seen[$k]}" != "${last_seen[$k]}" ]]; then
            echo "${last_seen[$k]}"  # ältestes (zusätzlich)
        fi
    done
}

# Datei-Backups
$QUIET || echo -e "${BOLD}── Datei-Backups ──────────────────────────────${NC}"
if [[ -d "$FILES_DIR" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if verify_file "$f" "files"; then
            $QUIET || log "$(basename "$f")"
            OK=$((OK+1))
        else
            $QUIET || warn "$(basename "$f")"
            FAILED=$((FAILED+1))
        fi
    done < <(collect_backups "$FILES_DIR" 's/_[0-9-]+\.tar\.gz(\.age)?$//')
fi

# DB-Backups
$QUIET || echo ""
$QUIET || echo -e "${BOLD}── DB-Backups ──────────────────────────────────${NC}"
if [[ -d "$DB_DIR" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if verify_file "$f" "db"; then
            $QUIET || log "$(basename "$f")"
            OK=$((OK+1))
        else
            $QUIET || warn "$(basename "$f")"
            FAILED=$((FAILED+1))
        fi
    done < <(collect_backups "$DB_DIR" 's/_[0-9_]+\.sql\.gz(\.age)?$//')
fi

# Ergebnis
$QUIET || echo ""
TOTAL=$((OK + FAILED))
if [[ $TOTAL -eq 0 ]]; then
    # Keine Backups gefunden ist KEIN Erfolg — meist fehlender Backup-Lauf/falsches Verzeichnis
    $QUIET || echo -e "${RED}Keine Backups gefunden — nichts zu verifizieren (verdächtig!)${NC}"
    STATUS="down"
    MSG="Backup-Verify FEHLER: keine Backups gefunden (${FILES_DIR}, ${DB_DIR})"
elif [[ $FAILED -eq 0 ]]; then
    $QUIET || echo -e "${GREEN}${TOTAL}/${TOTAL} Backups OK${NC}"
    STATUS="up"
    MSG="Backup-Verify: ${OK} Backups OK"
else
    $QUIET || echo -e "${RED}${FAILED}/${TOTAL} FEHLERHAFT:${NC}"
    $QUIET || for ff in "${FAILED_FILES[@]}"; do echo "  - $ff"; done
    STATUS="down"
    MSG="Backup-Verify FEHLER: ${FAILED}/${TOTAL} (${FAILED_FILES[*]})"
fi

# Slack-Alarm (nur bei Fehler — grüne Läufe erzeugen keinen Ping)
NOTIFY=false
for arg in "$@"; do [[ "$arg" == "--notify" ]] && NOTIFY=true; done
[[ -r /usr/local/lib/wp-hosting-notify.sh ]] && . /usr/local/lib/wp-hosting-notify.sh
if $NOTIFY && [[ "$STATUS" == "down" ]] && command -v notify >/dev/null 2>&1; then
    notify "Backup-Verify fehlgeschlagen" "${MSG}"
fi

[[ "$STATUS" == "up" ]] && exit 0 || exit 1
