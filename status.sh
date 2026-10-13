#!/bin/bash
# Übersichtliches Dashboard: Sites, Disk, Load, SSL, Updates, Maintenance
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Als root ausführen: sudo bash status.sh" >&2; exit 1; }
[[ ! -f /etc/wp-hosting/config ]] && { echo "Konfiguration nicht gefunden." >&2; exit 1; }
source /etc/wp-hosting/config

SITES_DIR="/etc/wp-hosting/sites"

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   WordPress Hosting Status — $(date '+%Y-%m-%d %H:%M')              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── System ────────────────────────────────────────────────────────────────
echo -e "${BOLD}── System ────────────────────────────────────────────────────${NC}"
HOSTNAME=$(hostname -s)
UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
CORES=$(nproc)
MEM_USED=$(free -h | awk '/^Mem:/ {print $3" / "$2}')
DISK_VAR=$(df -h /var/www 2>/dev/null | tail -1 | awk '{print $3" / "$2" ("$5")"}')

printf "  %-12s %s\n" "Host:"     "$HOSTNAME ($VM_TYPE)"
printf "  %-12s %s\n" "Uptime:"   "$UPTIME"
printf "  %-12s %s (Cores: %s)\n" "Load:"     "$LOAD" "$CORES"
printf "  %-12s %s\n" "Memory:"   "$MEM_USED"
printf "  %-12s %s\n" "Disk www:" "$DISK_VAR"
echo ""

# ── Services ──────────────────────────────────────────────────────────────
echo -e "${BOLD}── Services ──────────────────────────────────────────────────${NC}"
for svc in nginx php8.3-fpm redis-server fail2ban filebrowser; do
    if systemctl is-active --quiet "$svc"; then
        printf "  ${GREEN}●${NC} %-15s %s\n" "$svc" "running"
    else
        printf "  ${RED}●${NC} %-15s %s\n" "$svc" "STOPPED"
    fi
done

# Fail2ban Banned IPs
if command -v fail2ban-client &>/dev/null; then
    BANNED=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk -F: '{print $2}' | tr -d ' ' || echo "0")
    JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g' || echo "")
    TOTAL_BANNED=0
    for j in $JAILS; do
        N=$(fail2ban-client status "$j" 2>/dev/null | grep "Currently banned" | awk -F: '{print $2}' | tr -d ' \t' || echo "0")
        TOTAL_BANNED=$((TOTAL_BANNED + N))
    done
    printf "  %-15s %s aktiv, %s IPs gebannt\n" "fail2ban:" "${BANNED:-0}" "$TOTAL_BANNED"
fi
echo ""

# ── Sites ─────────────────────────────────────────────────────────────────
if [[ -n "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    echo -e "${BOLD}── Sites ─────────────────────────────────────────────────────${NC}"
    printf "  %-30s %-10s %-6s %-8s %-8s\n" "Domain" "Status" "SSL" "Files" "DB"
    echo "  ─────────────────────────────────────────────────────────────────"

    LIVE=0; MAINT=0
    for f in "$SITES_DIR"/*.txt; do
        DOMAIN=$(basename "$f" .txt)
        SITE_PATH="/var/www/${DOMAIN}"

        # Status
        if [[ -f "${SITE_PATH}/wp-content/.maintenance-active" ]]; then
            STATUS="${YELLOW}MAINT${NC}"
            MAINT=$((MAINT+1))
        else
            STATUS="${GREEN}LIVE${NC}"
            LIVE=$((LIVE+1))
        fi

        # SSL Tage (über Cloudflare prüfen wäre aufwendig — wir nutzen lokale state-files)
        SSL="?"
        SSL_FILE="/var/lib/wp-hosting/ssl-state/${DOMAIN}"
        if [[ -f "$SSL_FILE" ]]; then
            SSL_STATE=$(cat "$SSL_FILE" 2>/dev/null || echo "?")
            [[ "$SSL_STATE" == "ok" ]] && SSL="${GREEN}OK${NC}" || SSL="${RED}${SSL_STATE}${NC}"
        else
            SSL="${BLUE}—${NC}"
        fi

        # Files-Größe
        if [[ -d "$SITE_PATH" ]]; then
            FILES=$(du -sh "$SITE_PATH" 2>/dev/null | awk '{print $1}')
        else
            FILES="—"
        fi

        # DB-Größe (per information_schema)
        DB_NAME=$(grep "^DB-Name:" "$f" 2>/dev/null | awk '{print $2}')
        DB_SIZE="—"
        if [[ -n "$DB_NAME" ]]; then
            DB_BYTES=$(MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -N -B \
                -e "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo "0")
            if [[ "$DB_BYTES" -gt 0 ]]; then
                DB_SIZE=$(awk -v b="$DB_BYTES" 'BEGIN { if (b<1048576) printf "%dK", b/1024; else if (b<1073741824) printf "%.0fM", b/1048576; else printf "%.1fG", b/1073741824 }')
            fi
        fi

        printf "  %-30s " "$DOMAIN"
        echo -e "${STATUS}      ${SSL}    ${FILES}     ${DB_SIZE}"
    done
    echo ""
    echo -e "  ${GREEN}${LIVE} LIVE${NC} | ${YELLOW}${MAINT} MAINT${NC} | Total: $((LIVE + MAINT))"
    echo ""
fi

# ── Pending Updates (apt) ─────────────────────────────────────────────────
if command -v apt-get &>/dev/null; then
    UPDATES=$(apt-get -s upgrade 2>/dev/null | grep -c "^Inst" || echo "0")
    SECURITY=$(apt-get -s upgrade 2>/dev/null | grep "^Inst" | grep -ci security || echo "0")
    if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${BOLD}── Updates ───────────────────────────────────────────────────${NC}"
        if [[ "$SECURITY" -gt 0 ]]; then
            echo -e "  ${RED}${UPDATES} Pakete${NC} verfügbar (davon ${RED}${SECURITY} Sicherheits-Updates${NC})"
        else
            echo -e "  ${YELLOW}${UPDATES} Pakete${NC} verfügbar"
        fi
        echo -e "  → ${BLUE}sudo apt update && sudo apt upgrade${NC}"
        echo ""
    fi
fi

# ── Backups ───────────────────────────────────────────────────────────────
if [[ -d /var/backups/wp-files ]] || [[ -d /var/backups/mysql ]]; then
    echo -e "${BOLD}── Backups ───────────────────────────────────────────────────${NC}"
    LAST_FILE_BU=$(ls -t /var/backups/wp-files/*.tar.gz* 2>/dev/null | head -1 || true)
    LAST_DB_BU=$(ls -t /var/backups/mysql/*.sql.gz* 2>/dev/null | head -1 || true)

    if [[ -n "$LAST_FILE_BU" ]]; then
        AGE=$(( ($(date +%s) - $(stat -c %Y "$LAST_FILE_BU")) / 3600 ))
        printf "  %-15s %s (vor %dh)\n" "Files (latest):" "$(basename "$LAST_FILE_BU")" "$AGE"
    fi
    if [[ -n "$LAST_DB_BU" ]]; then
        AGE=$(( ($(date +%s) - $(stat -c %Y "$LAST_DB_BU")) / 3600 ))
        printf "  %-15s %s (vor %dh)\n" "DB (latest):"    "$(basename "$LAST_DB_BU")" "$AGE"
    fi

    [[ -f /etc/wp-hosting/backup-recipient.txt ]] && \
        echo -e "  Verschlüsselung: ${GREEN}aktiv (age)${NC}" || \
        echo -e "  Verschlüsselung: ${YELLOW}inaktiv${NC}"
    echo ""
fi

echo -e "${BOLD}Befehle:${NC}"
echo -e "  ${BLUE}sudo bash health-check.sh${NC}    — Detail-Health-Check (HTTP, FPM, DB, Redis)"
echo -e "  ${BLUE}sudo bash list-sites.sh${NC}      — Alle Sites mit Credentials"
echo -e "  ${BLUE}sudo bash backup-verify.sh${NC}   — Backups verifizieren"
echo -e "  ${BLUE}sudo bash tail-logs.sh <domain>${NC} — Live-Logs"
echo ""
