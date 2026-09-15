#!/bin/bash
# Zentraler Entschlüsselungs-Check für wp-hosting-Backups.
#
# Läuft NICHT auf den Web-VMs — die halten bewusst nur den öffentlichen
# age-Recipient, nicht den privaten Key (keys/wp-hosting age Stack-Key in
# 1Password). backup-verify.sh prüft dort deshalb nur noch Existenz/Größe;
# die echte Entschlüsselbarkeit prüft dieses Script von einem Host mit
# 1Password-Zugriff (Admin-Mac, Ops-Host).
#
# Holt je VM das jüngste Datei- und DB-Backup per scp, entschlüsselt lokal,
# prüft tar- bzw. SQL-Struktur. Key liegt nur für die Laufzeit als 600-Datei
# im eigenen Tempdir, wird per EXIT-Trap sicher entfernt (rm -P).
#
# Voraussetzung: `op` ist authentifiziert (OP_SERVICE_ACCOUNT_TOKEN gesetzt
# oder Desktop-Integration entsperrt), SSH-Zugriff auf die Web-VMs.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# Fleet: Platzhalter-Beispiel — echte IPs gehören nicht ins öffentliche Repo.
# Immer per CLI-Args aufrufen: verify-backups-central.sh <ip1> <ip2> ...
DEFAULT_VMS=(192.168.1.101 192.168.1.102 192.168.1.103)
if [[ $# -gt 0 ]]; then
    VMS=("$@")
else
    VMS=("${DEFAULT_VMS[@]}")
fi

command -v op   >/dev/null || { err "'op' nicht gefunden."; exit 1; }
command -v age  >/dev/null || { err "'age' nicht gefunden (brew install age)."; exit 1; }

TMP=$(mktemp -d)
# $? in der Trap-Kette selbst erfassen und am Ende erneut exiten — sonst
# überschreibt der letzte Aufräum-Befehl den eigentlich beabsichtigten Exit-Code.
trap 'code=$?; rm -P "$TMP/key.txt" 2>/dev/null; rm -rf "$TMP"; exit $code' EXIT

info "Hole privaten age-Key aus 1Password (keys/wp-hosting age Stack-Key)…"
op read "op://keys/wp-hosting age Stack-Key/private_key" > "$TMP/key.txt" 2>"$TMP/op-err.txt"
if [[ ! -s "$TMP/key.txt" ]]; then
    err "Key konnte nicht geholt werden:"; cat "$TMP/op-err.txt" >&2
    exit 1
fi
chmod 600 "$TMP/key.txt"
log "Key geholt (bleibt nur im Tempdir, wird am Ende sicher entfernt)"

OK=0
FAILED=0
FAILED_ITEMS=()

check_one() {
    local vm="$1" remote_path="$2" kind="$3"   # kind: files|db
    local base local_file
    base=$(basename "$remote_path")
    local_file="$TMP/$base"

    if ! scp -q -o ConnectTimeout=10 "root@${vm}:${remote_path}" "$local_file" 2>/dev/null; then
        FAILED_ITEMS+=("${vm}:${base} (scp fehlgeschlagen)")
        FAILED=$((FAILED+1))
        return
    fi

    if [[ "$kind" == "files" ]]; then
        if age -d -i "$TMP/key.txt" "$local_file" 2>/dev/null | tar -tzf - >/dev/null 2>&1; then
            log "${vm}:${base}"
            OK=$((OK+1))
        else
            FAILED_ITEMS+=("${vm}:${base} (Entschlüsselung/tar)")
            FAILED=$((FAILED+1))
        fi
    else
        local content
        content=$(age -d -i "$TMP/key.txt" "$local_file" 2>/dev/null | zcat 2>/dev/null | head -c 4096) || true
        if echo "$content" | grep -qE "^(CREATE|INSERT|--|/\*)"; then
            log "${vm}:${base}"
            OK=$((OK+1))
        else
            FAILED_ITEMS+=("${vm}:${base} (kein SQL-Inhalt)")
            FAILED=$((FAILED+1))
        fi
    fi
    rm -f "$local_file"
}

for vm in "${VMS[@]}"; do
    echo
    info "=== $vm ==="

    newest_files=$(ssh -o ConnectTimeout=10 "root@${vm}" \
        'find /var/backups/wp-files -maxdepth 1 -name "*.tar.gz.age" -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2-' 2>/dev/null || true)
    newest_db=$(ssh -o ConnectTimeout=10 "root@${vm}" \
        'find /var/backups/mysql -maxdepth 1 -name "*.sql.gz.age" -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2-' 2>/dev/null || true)

    [[ -n "$newest_files" ]] && check_one "$vm" "$newest_files" files || warn "$vm: kein Datei-Backup (.age) gefunden"
    [[ -n "$newest_db" ]]    && check_one "$vm" "$newest_db" db       || warn "$vm: kein DB-Backup (.age) gefunden"
done

echo
TOTAL=$((OK + FAILED))
if [[ $FAILED -eq 0 ]]; then
    log "${OK}/${TOTAL} entschlüsselt und geprüft — alles OK"
    exit 0
else
    err "${FAILED}/${TOTAL} fehlgeschlagen:"
    for i in "${FAILED_ITEMS[@]}"; do echo "  - $i"; done
    exit 1
fi
