#!/bin/bash
# Stellt eine WordPress-Site aus einem lokalen Backup wieder her
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash restore-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

source /etc/wp-hosting/config

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site wiederherstellen            ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Site auswählen ────────────────────────────────────────────────────────
SITES_DIR="/etc/wp-hosting/sites"
FILES_BACKUP_DIR="/var/backups/wp-files"

if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    err "Keine installierten Sites gefunden."
fi

echo "Installierte Sites:"
for f in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$f" .txt)
    TYPE=$(grep "^Typ:" "$f" 2>/dev/null | awk '{print $2}' || echo "?")
    echo "  - ${DOMAIN} (${TYPE})"
done
echo ""
read -rp "Domain der wiederherzustellenden Site: " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."

CRED_FILE="${SITES_DIR}/${DOMAIN}.txt"
[[ ! -f "$CRED_FILE" ]] && err "Site '${DOMAIN}' nicht gefunden."

SITE_PATH="/var/www/${DOMAIN}"
# Systemuser aus der Cred-Datei lesen, NICHT aus der Domain ableiten: install-wp benennt
# ihn wp_<12-alnum>_<sha256-8>. Die alte Ableitung ergab einen nicht existierenden Namen
# — die chown -R auf wp-content wären damit ins Leere gelaufen und hätten die
# wiederhergestellten Dateien im falschen Eigentum gelassen (Site kann nicht schreiben).
SYSTEM_USER=$(sed -nE 's/^System-User:[[:space:]]*//p' "$CRED_FILE" | head -1)
if [[ -z "$SYSTEM_USER" ]]; then
    DOMAIN_SAFE="$(printf '%s' "$DOMAIN" | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-8)"
    SYSTEM_USER="wp_${DOMAIN_SAFE}"
    warn "System-User nicht in ${CRED_FILE} — abgeleitet: ${SYSTEM_USER}"
fi
id "$SYSTEM_USER" &>/dev/null || err "Systemuser '${SYSTEM_USER}' existiert nicht — Restore abgebrochen (Dateirechte wären falsch)."

DB_NAME=$(grep "^DB-Name:" "$CRED_FILE" | awk '{print $2}')
DB_USER=$(grep "^DB-User:" "$CRED_FILE" | awk '{print $2}')
DB_PASS=$(grep "^DB-Pass:" "$CRED_FILE" | awk '{print $2}')

# ── Was soll wiederhergestellt werden? ────────────────────────────────────
echo ""
echo "Was soll wiederhergestellt werden?"
echo "  1) Nur Dateien (wp-content)"
echo "  2) Nur Datenbank"
echo "  3) Beides (Dateien + Datenbank)"
echo ""
read -rp "Auswahl [1/2/3]: " restore_choice
case "$restore_choice" in
    1) RESTORE_FILES=true;  RESTORE_DB=false ;;
    2) RESTORE_FILES=false; RESTORE_DB=true  ;;
    3) RESTORE_FILES=true;  RESTORE_DB=true  ;;
    *) err "Ungültige Auswahl." ;;
esac

# ── Datei-Backup auswählen ────────────────────────────────────────────────
BACKUP_FILE=""
if $RESTORE_FILES; then
    echo ""
    echo "Verfügbare Datei-Backups für ${DOMAIN}:"
    BACKUPS=()
    while IFS= read -r f; do
        BACKUPS+=("$f")
    done < <(ls -t "${FILES_BACKUP_DIR}/${DOMAIN}_"*.tar.gz "${FILES_BACKUP_DIR}/${DOMAIN}_"*.tar.gz.age 2>/dev/null || true)

    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        warn "Keine lokalen Datei-Backups gefunden in ${FILES_BACKUP_DIR}"
        echo ""
        read -rp "Pfad zu einer tar.gz-Datei (leer = Dateien überspringen): " CUSTOM_TAR
        if [[ -n "$CUSTOM_TAR" ]]; then
            [[ ! -f "$CUSTOM_TAR" ]] && err "Datei nicht gefunden: ${CUSTOM_TAR}"
            BACKUP_FILE="$CUSTOM_TAR"
        else
            RESTORE_FILES=false
        fi
    else
        for i in "${!BACKUPS[@]}"; do
            SIZE=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
            DATE=$(basename "${BACKUPS[$i]}" | sed "s/${DOMAIN}_//" | sed 's/\.tar\.gz//')
            echo "  $((i+1))) ${DATE}  (${SIZE})"
        done
        echo ""
        read -rp "Auswahl [1-${#BACKUPS[@]}]: " file_choice
        [[ ! "$file_choice" =~ ^[0-9]+$ ]] || \
        [[ $file_choice -lt 1 ]] || [[ $file_choice -gt ${#BACKUPS[@]} ]] && \
            err "Ungültige Auswahl."
        BACKUP_FILE="${BACKUPS[$((file_choice-1))]}"
    fi
fi

# ── DB-Backup auswählen ───────────────────────────────────────────────────
SQL_FILE=""
if $RESTORE_DB; then
    echo ""
    echo "Datenbankwiederherstellung — Optionen:"
    echo "  1) Aus lokalem MariaDB-Backup (/var/backups/mysql)"
    echo "  2) Pfad zu SQL-Datei manuell angeben (.sql oder .sql.gz)"
    echo ""
    read -rp "Auswahl [1/2]: " db_choice

    case "$db_choice" in
        1)
            # DB-Backups entstehen laut Architektur auf der DB-VM (mysql-backup.sh) bzw.
            # liegen in R2 — lokal auf der Web-VM existiert /var/backups/mysql meist NICHT.
            # Nur DOMAIN-spezifisch suchen — kein Blind-Fallback auf *.sql.gz
            # (der könnte einen --all-databases-Dump o.ä. erwischen).
            DB_BACKUPS=()
            while IFS= read -r f; do
                DB_BACKUPS+=("$f")
            done < <(ls -t "/var/backups/mysql/${DB_NAME}_"*.sql.gz "/var/backups/mysql/${DB_NAME}_"*.sql.gz.age 2>/dev/null || true)

            if [[ ${#DB_BACKUPS[@]} -eq 0 ]]; then
                warn "Keine DB-Backups für '${DB_NAME}' in /var/backups/mysql/ gefunden."
                warn "DB-Backups liegen i.d.R. auf der DB-VM oder in R2 — von dort holen und via Option 2 (manueller Pfad) einspielen."
                RESTORE_DB=false
            else
                echo "Verfügbare DB-Backups:"
                for i in "${!DB_BACKUPS[@]}"; do
                    SIZE=$(du -sh "${DB_BACKUPS[$i]}" 2>/dev/null | cut -f1)
                    echo "  $((i+1))) $(basename "${DB_BACKUPS[$i]}")  (${SIZE})"
                done
                echo ""
                read -rp "Auswahl [1-${#DB_BACKUPS[@]}]: " db_idx
                { [[ ! "$db_idx" =~ ^[0-9]+$ ]] || [[ $db_idx -lt 1 ]] || [[ $db_idx -gt ${#DB_BACKUPS[@]} ]]; } && err "Ungültige Auswahl."
                SQL_FILE="${DB_BACKUPS[$((db_idx-1))]}"
            fi
            ;;
        2)
            read -rp "Pfad zur SQL-Datei (.sql oder .sql.gz): " SQL_FILE
            [[ ! -f "$SQL_FILE" ]] && err "Datei nicht gefunden: ${SQL_FILE}"
            ;;
        *) err "Ungültige Auswahl." ;;
    esac
fi

# ── Zusammenfassung und Bestätigung ──────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}ACHTUNG — folgende Daten werden überschrieben:${NC}"
echo -e "  Site:    ${BOLD}${DOMAIN}${NC}"
$RESTORE_FILES && echo -e "  Dateien: ${BOLD}${BACKUP_FILE}${NC} → ${SITE_PATH}/wp-content/"
$RESTORE_DB    && echo -e "  DB:      ${BOLD}${SQL_FILE}${NC} → ${DB_NAME}"
echo ""
read -rp "Wiederherstellung starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Maintenance Mode aktivieren ───────────────────────────────────────────
MAINT_FLAG="${SITE_PATH}/wp-content/.maintenance-active"
touch "$MAINT_FLAG" && chown "${SYSTEM_USER}:www-data" "$MAINT_FLAG" 2>/dev/null || true
log "Maintenance Mode aktiviert"

# ── Dateien wiederherstellen ──────────────────────────────────────────────
ROLLBACK=""  # Wird unten gesetzt wenn altes wp-content gesichert wurde
if $RESTORE_FILES && [[ -n "$BACKUP_FILE" ]]; then
    info "Dateien werden wiederhergestellt aus: $(basename "$BACKUP_FILE")"

    # wp-content sichern und ersetzen
    CONTENT_PATH="${SITE_PATH}/wp-content"
    TMP_RESTORE="/tmp/wp-restore-${DOMAIN_SAFE}-$(date +%s)"
    mkdir -p "$TMP_RESTORE"

    # age-verschlüsselt? → entschlüsseln
    if [[ "$BACKUP_FILE" == *.age ]]; then
        AGE_KEY="/etc/wp-hosting/backup-key.txt"
        [[ ! -f "$AGE_KEY" ]] && err "Verschlüsseltes Backup, aber ${AGE_KEY} fehlt."
        command -v age &>/dev/null || err "age nicht installiert."
        info "Backup wird entschlüsselt..."
        age -d -i "$AGE_KEY" "$BACKUP_FILE" | tar -xzf - -C "$TMP_RESTORE" 2>/dev/null
    else
        tar -xzf "$BACKUP_FILE" -C "$TMP_RESTORE" 2>/dev/null
    fi

    # wp-content aus Backup ermitteln
    if [[ -d "${TMP_RESTORE}/wp-content" ]]; then
        SRC_CONTENT="${TMP_RESTORE}/wp-content"
    else
        SRC_CONTENT=$(find "$TMP_RESTORE" -maxdepth 2 -type d -name "wp-content" | head -1) || true  # head schließt Pipe → find SIGPIPE (141) unter pipefail
    fi

    if [[ -z "$SRC_CONTENT" ]]; then
        rm -rf "$TMP_RESTORE"
        err "wp-content Verzeichnis nicht im Backup gefunden."
    fi

    # Aktuelles wp-content sichern (im äußeren Scope für Auto-Rollback)
    if [[ -d "$CONTENT_PATH" ]]; then
        ROLLBACK="${CONTENT_PATH}.rollback-$(date +%Y%m%d%H%M%S)"
        mv "$CONTENT_PATH" "$ROLLBACK"
        warn "Altes wp-content gesichert: ${ROLLBACK}"
    fi

    cp -a "$SRC_CONTENT" "$CONTENT_PATH"
    chown -R "${SYSTEM_USER}:www-data" "$CONTENT_PATH"
    find "$CONTENT_PATH" -type d -exec chmod 750 {} \;
    find "$CONTENT_PATH" -type f -exec chmod 640 {} \;
    rm -rf "$TMP_RESTORE"

    # Maintenance-Flag nach Berechtigungen neu setzen
    touch "$MAINT_FLAG" && chown "${SYSTEM_USER}:www-data" "$MAINT_FLAG" && chmod 640 "$MAINT_FLAG" 2>/dev/null || true

    log "Dateien wiederhergestellt: ${CONTENT_PATH}"
fi

# ── Datenbank wiederherstellen ────────────────────────────────────────────
if $RESTORE_DB && [[ -n "$SQL_FILE" ]]; then
    info "Datenbank wird wiederhergestellt aus: $(basename "$SQL_FILE")"

    # Pre-Restore-Snapshot der aktuellen DB (für Auto-Rollback bei Import-Fehler)
    DB_ROLLBACK_DIR="/var/backups/wp-restore-rollback"
    DB_ROLLBACK="${DB_ROLLBACK_DIR}/${DB_NAME}_$(date +%Y%m%d%H%M%S).sql.gz"
    mkdir -p "$DB_ROLLBACK_DIR"; chmod 700 "$DB_ROLLBACK_DIR"
    info "Sichere aktuelle DB vor Import → ${DB_ROLLBACK}"
    if ! MYSQL_PWD="$DB_ADMIN_PASS" mysqldump -h "$DB_HOST" -u "$DB_ADMIN_USER" \
            --single-transaction --quick "$DB_NAME" 2>/dev/null | gzip > "$DB_ROLLBACK"; then
        rm -f "$DB_ROLLBACK"
        err "Pre-Restore-Snapshot der DB fehlgeschlagen — Import abgebrochen (DB unverändert)."
    fi

    # Import-Helfer: entschlüsselt/entpackt je nach Endung, spielt in die DB
    _db_import() {
        if [[ "$SQL_FILE" == *.age ]]; then
            local AGE_KEY="/etc/wp-hosting/backup-key.txt"
            [[ ! -f "$AGE_KEY" ]] && { warn "backup-key.txt fehlt"; return 1; }
            command -v age &>/dev/null || { warn "age nicht installiert"; return 1; }
            age -d -i "$AGE_KEY" "$SQL_FILE" | zcat | \
                MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" "$DB_NAME"
        elif [[ "$SQL_FILE" == *.gz ]]; then
            zcat "$SQL_FILE" | MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" "$DB_NAME"
        else
            MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" "$DB_NAME" < "$SQL_FILE"
        fi
    }

    # Tabellen leeren (nicht DB droppen — User-Rechte bleiben erhalten).
    # Fehler NICHT schlucken: bei Problemen abbrechen, DB ist noch unverändert.
    TABLES=$(MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" \
        -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
        --skip-column-names 2>/dev/null || echo "")
    if [[ -n "$TABLES" ]]; then
        DROP_SQL=$( { echo "SET FOREIGN_KEY_CHECKS=0;"; \
            while IFS= read -r tbl; do [[ -n "$tbl" ]] && printf 'DROP TABLE IF EXISTS `%s`;\n' "$tbl"; done <<< "$TABLES"; \
            echo "SET FOREIGN_KEY_CHECKS=1;"; } )
        if ! printf '%s\n' "$DROP_SQL" | MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" "$DB_NAME"; then
            err "Tabellen konnten nicht geleert werden — Import abgebrochen (DB unverändert, Snapshot: ${DB_ROLLBACK})."
        fi
    fi

    # Import — bei Fehler DB aus Pre-Restore-Snapshot zurückrollen
    if _db_import; then
        log "Datenbank wiederhergestellt: ${DB_NAME}"
        info "Pre-Restore-Snapshot bleibt vorhanden: ${DB_ROLLBACK}"
    else
        warn "Import fehlgeschlagen — DB wird aus Pre-Restore-Snapshot zurückgerollt..."
        if { echo "SET FOREIGN_KEY_CHECKS=0;"; zcat "$DB_ROLLBACK"; echo "SET FOREIGN_KEY_CHECKS=1;"; } | \
                MYSQL_PWD="$DB_ADMIN_PASS" mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" "$DB_NAME"; then
            err "Import fehlgeschlagen, DB erfolgreich zurückgerollt (Stand vor Restore wiederhergestellt)."
        else
            err "Import UND Rollback fehlgeschlagen — DB möglicherweise inkonsistent. Snapshot: ${DB_ROLLBACK}"
        fi
    fi
fi

# ── Caches leeren ─────────────────────────────────────────────────────────
command -v wp &>/dev/null && wp cache flush --path="$SITE_PATH" --allow-root 2>/dev/null || true
[[ -d /var/cache/nginx/wp ]] && rm -rf /var/cache/nginx/wp/* 2>/dev/null || true
log "Caches geleert"

# ── HTTP-Test & Auto-Rollback ─────────────────────────────────────────────
# Maintenance-Mode liefert 503 → für den Test temporär deaktivieren
info "Verifiziere Site..."
rm -f "$MAINT_FLAG" 2>/dev/null || true
sleep 1

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 15 \
    -H "Host: ${DOMAIN}" \
    "http://127.0.0.1/" 2>/dev/null || echo "ERR")

# Maintenance-Mode wieder aktivieren
touch "$MAINT_FLAG" && chown "${SYSTEM_USER}:www-data" "$MAINT_FLAG" 2>/dev/null || true

HTTP_OK=true
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    log "HTTP-Test OK (${HTTP_CODE})"
else
    HTTP_OK=false
    warn "HTTP-Test FEHLGESCHLAGEN (${HTTP_CODE})"
    if $RESTORE_FILES && [[ -n "$ROLLBACK" && -d "$ROLLBACK" ]]; then
        echo ""
        read -rp "Auto-Rollback der Dateien durchführen? [j/N]: " do_rollback
        if [[ "$do_rollback" == "j" || "$do_rollback" == "J" ]]; then
            rm -rf "${SITE_PATH}/wp-content"
            mv "$ROLLBACK" "${SITE_PATH}/wp-content"
            chown -R "${SYSTEM_USER}:www-data" "${SITE_PATH}/wp-content"
            log "Rollback durchgeführt — Site auf vorherigen Stand zurückgesetzt"
        else
            warn "Rollback übersprungen — Backup liegt unter: ${ROLLBACK}"
        fi
    fi
fi

# ── Ausgabe ───────────────────────────────────────────────────────────────
# Kein Erfolg vortäuschen, wenn gar nichts wiederhergestellt wurde
if ! $RESTORE_FILES && ! $RESTORE_DB; then
    err "Es wurde nichts wiederhergestellt (keine Dateien/DB ausgewählt oder kein Backup gefunden)."
fi
echo ""
if [[ "${HTTP_OK:-true}" == "true" ]]; then
    echo -e "${BOLD}╔══════════════════════════════════════════════╗"
    echo -e "║   Wiederherstellung abgeschlossen ✓          ║"
    echo -e "╚══════════════════════════════════════════════╝${NC}"
else
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗"
    echo -e "║   Wiederherstellung mit FEHLER (HTTP-Test)   ║"
    echo -e "╚══════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "  Domain:  ${BOLD}https://${DOMAIN}${NC}"
$RESTORE_FILES && echo -e "  Dateien: ${BOLD}wiederhergestellt${NC}"
$RESTORE_DB    && echo -e "  DB:      ${BOLD}wiederhergestellt${NC}"
echo ""
echo -e "${YELLOW}  → Site ist im Maintenance Mode — prüfen und freischalten:${NC}"
echo -e "${YELLOW}    sudo bash maintenance.sh${NC}"
echo ""
# Exit-Code für Automatisierung: non-zero, wenn der HTTP-Test fehlschlug
[[ "${HTTP_OK:-true}" == "true" ]] && exit 0 || exit 1
