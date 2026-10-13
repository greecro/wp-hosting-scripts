#!/bin/bash
# Zeigt alle installierten WordPress-Sites mit Status
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Als root ausführen."; exit 1; }
[[ ! -f /etc/wp-hosting/config ]] && { echo "Konfiguration nicht gefunden."; exit 1; }

source /etc/wp-hosting/config

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Sites — Übersicht                ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

SITES_DIR="/etc/wp-hosting/sites"
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    echo "  Keine Sites installiert."
    exit 0
fi

TOTAL=0; RUNNING=0; ISSUES=0

printf "  %-30s %-12s %-12s %-7s %-7s %-7s\n" "DOMAIN" "TYP" "STATUS" "FILES" "DB" "SVCS"
echo "  $(printf '%.0s─' {1..90})"

for CRED_FILE in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$CRED_FILE" .txt)
    SITE_PATH="/var/www/${DOMAIN}"

    TYPE=$(grep "^Typ:" "$CRED_FILE" 2>/dev/null | awk '{print $2}' || echo "?")
    DB_NAME=$(grep "^DB-Name:" "$CRED_FILE" 2>/dev/null | awk '{print $2}' || echo "")

    # Maintenance Mode?
    if [[ -f "${SITE_PATH}/wp-content/.maintenance-active" ]]; then
        MAINT_STATUS="${YELLOW}[MAINT]${NC}"
    else
        MAINT_STATUS="${GREEN}[LIVE] ${NC}"
        RUNNING=$((RUNNING + 1))
    fi

    # Files-Größe
    FILES_SIZE=$( [[ -d "$SITE_PATH" ]] && du -sh "$SITE_PATH" 2>/dev/null | awk '{print $1}' || echo "—")

    # DB-Größe
    DB_SIZE="—"
    if [[ -n "$DB_NAME" ]]; then
        DB_BYTES=$(MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -N -B \
            -e "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo "0")
        if [[ "$DB_BYTES" -gt 0 ]]; then
            DB_SIZE=$(awk -v b="$DB_BYTES" 'BEGIN { if (b<1048576) printf "%dK", b/1024; else if (b<1073741824) printf "%.0fM", b/1048576; else printf "%.1fG", b/1073741824 }')
        fi
    fi

    # Service-Indikatoren (kompakt: nginx/php-fpm)
    SVC=""
    [[ -L "/etc/nginx/sites-enabled/${DOMAIN}" ]] && SVC="${SVC}${GREEN}N${NC}" || { SVC="${SVC}${RED}N${NC}"; ISSUES=$((ISSUES+1)); }
    [[ -S "/run/php/php8.3-fpm-${DOMAIN}.sock" ]] && SVC="${SVC}${GREEN}P${NC}" || { SVC="${SVC}${RED}P${NC}"; ISSUES=$((ISSUES+1)); }
    if command -v redis-cli &>/dev/null && redis-cli ping &>/dev/null; then
        SVC="${SVC}${GREEN}R${NC}"
    else
        SVC="${SVC}${RED}R${NC}"
    fi

    printf "  %-30s %-12s " "$DOMAIN" "$TYPE"
    echo -e "${MAINT_STATUS}  ${FILES_SIZE}     ${DB_SIZE}     ${SVC}"

    TOTAL=$((TOTAL + 1))
done

echo ""
echo "  Gesamt: ${BOLD}${TOTAL}${NC} Sites | Live: ${BOLD}${RUNNING}${NC} | Maintenance: ${BOLD}$((TOTAL - RUNNING))${NC}"
[[ $ISSUES -gt 0 ]] && echo -e "  ${YELLOW}Hinweis: ${ISSUES} Problem(e) erkannt — Nginx/PHP-FPM prüfen.${NC}"
echo -e "  ${BLUE}SVCS: N=Nginx P=PHP-FPM R=Redis (grün=OK, rot=Problem)${NC}"

# VM-Status
echo ""
echo -e "  ${BOLD}VM-Status:${NC}"
echo -e "  Nginx:      $(systemctl is-active nginx       2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  PHP-FPM:    $(systemctl is-active php8.3-fpm  2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  Redis:      $(systemctl is-active redis-server 2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  Netdata:    $(systemctl is-active netdata      2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  VM-Typ:     ${BOLD}${VM_TYPE}${NC} | DB-Host: ${BOLD}${DB_HOST}${NC}"
echo ""

# Disk-Nutzung
echo -e "  ${BOLD}Disk-Nutzung /var/www:${NC}"
du -sh /var/www/*/  2>/dev/null | sort -rh | head -10 | awk '{printf "  %-10s %s\n", $1, $2}' || true
echo ""
