#!/bin/bash
# Einmalige Einrichtung der Datenbank-VM (MariaDB, optimiert für WordPress/WooCommerce)
# Voraussetzung: Ubuntu 24.04 LTS, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash setup-db.sh"

# ── Non-interaktiver Modus: --config <datei> ──────────────────────────────
NONINT=false
if [[ "${1:-}" == "--config" ]]; then
    [[ -z "${2:-}" ]] && err "--config braucht einen Dateipfad."
    [[ -f "$2" ]] || err "Config-Datei nicht gefunden: $2"
    # shellcheck disable=SC1090
    source "$2"
    NONINT=true
fi

# ask VAR "Prompt" — fragt nur interaktiv und nur wenn VAR noch leer ist.
ask() {
    local __var="$1" __prompt="$2"
    [[ -n "${!__var:-}" ]] && return 0
    if $NONINT; then printf -v "$__var" '%s' ""; return 0; fi
    read -rp "$__prompt" "$__var"
}
confirm_or_die() {
    $NONINT && return 0
    local ans; read -rp "$1" ans
    [[ "$ans" != "j" && "$ans" != "J" ]] && err "Abgebrochen."
}

# clear scheitert ohne TERM (z.B. non-interaktiv über SSH) und würde mit set -e
# das ganze Skript killen → non-fatal machen.
clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Datenbank-VM Setup — Ubuntu 24.04          ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

ask WEB_VM_IPS "IPs der Web-VMs, kommagetrennt (z.B. 192.168.1.10,192.168.1.11): "
[[ -z "${WEB_VM_IPS:-}" ]] && err "Mindestens eine Web-VM-IP angeben (WEB_VM_IPS)."

ask SLACK_WEBHOOK_URL "Slack Incoming Webhook-URL für Alerts (leer = deaktiviert): "
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

ask AGE_RECIPIENT "age Public-Key für Backup-Verschlüsselung (leer = unverschlüsselt): "
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
[[ -n "$AGE_RECIPIENT" && ! "$AGE_RECIPIENT" =~ ^age1 ]] && err "Ungültiger age Public-Key (muss mit 'age1' beginnen)."

# Hostname für eindeutigen Pfad (Konsistenz mit Web-VMs, future-proof bei mehreren DB-VMs)
DB_HOSTNAME=$(hostname -s)

RCLONE_REMOTE="${RCLONE_REMOTE:-}"
if [[ -n "$RCLONE_REMOTE" ]]; then
    # Config-Modus: Remote vorab gesetzt → Felder aus Config, RCLONE_DEST ableiten.
    case "$RCLONE_REMOTE" in
        r2)
            [[ -z "${R2_ACCOUNT_ID:-}" || -z "${R2_KEY_ID:-}" || -z "${R2_KEY_SECRET:-}" || -z "${R2_BUCKET:-}" ]] && \
                err "R2-Config unvollständig (R2_ACCOUNT_ID/R2_KEY_ID/R2_KEY_SECRET/R2_BUCKET)."
            RCLONE_CHOICE=1; RCLONE_DEST="r2:${R2_BUCKET}/${DB_HOSTNAME}" ;;
        s3backup)
            [[ -z "${S3_BUCKET:-}" || -z "${S3_KEY_ID:-}" || -z "${S3_KEY_SECRET:-}" ]] && \
                err "S3-Config unvollständig (S3_BUCKET/S3_KEY_ID/S3_KEY_SECRET)."
            S3_REGION="${S3_REGION:-}"; S3_ENDPOINT="${S3_ENDPOINT:-}"
            RCLONE_CHOICE=2; RCLONE_DEST="s3backup:${S3_BUCKET}/${DB_HOSTNAME}" ;;
        sftpbackup)
            [[ -z "${SFTP_HOST:-}" || -z "${SFTP_USER:-}" || -z "${SFTP_PATH:-}" ]] && \
                err "SFTP-Config unvollständig (SFTP_HOST/SFTP_USER/SFTP_PATH)."
            SFTP_PORT="${SFTP_PORT:-22}"
            RCLONE_CHOICE=3; RCLONE_DEST="sftpbackup:${SFTP_PATH}/${DB_HOSTNAME}" ;;
        *) err "Ungültiger RCLONE_REMOTE: ${RCLONE_REMOTE} (erlaubt: r2, s3backup, sftpbackup)." ;;
    esac
else
    $NONINT && err "RCLONE_REMOTE ist im --config-Modus Pflicht (r2 | s3backup | sftpbackup)."
    echo ""
    echo -e "${BOLD}Remote-Backup für MariaDB-Dumps — PFLICHT${NC}"
    echo "  1) Cloudflare R2"
    echo "  2) S3-kompatibel (AWS, MinIO, etc.)"
    echo "  3) SFTP"
    echo ""
    while [[ -z "$RCLONE_REMOTE" ]]; do
    read -rp "Auswahl [1-3]: " RCLONE_CHOICE
    case "$RCLONE_CHOICE" in
        1)
            read -rp "R2 Account-ID: " R2_ACCOUNT_ID
            read -rp "R2 Access Key ID: " R2_KEY_ID
            read -rsp "R2 Access Key Secret: " R2_KEY_SECRET; echo ""
            read -rp "R2 Bucket-Name: " R2_BUCKET
            [[ -z "$R2_ACCOUNT_ID" || -z "$R2_KEY_ID" || -z "$R2_KEY_SECRET" || -z "$R2_BUCKET" ]] && \
                { warn "Alle R2-Felder sind Pflicht — bitte erneut eingeben."; continue; }
            RCLONE_REMOTE="r2"
            RCLONE_DEST="r2:${R2_BUCKET}/${DB_HOSTNAME}"
            ;;
        2)
            read -rp "S3 Region (z.B. eu-central-1): " S3_REGION
            read -rp "S3 Bucket-Name: " S3_BUCKET
            read -rp "S3 Access Key ID: " S3_KEY_ID
            read -rsp "S3 Access Key Secret: " S3_KEY_SECRET; echo ""
            read -rp "S3 Endpoint (leer = AWS Standard): " S3_ENDPOINT
            [[ -z "$S3_BUCKET" || -z "$S3_KEY_ID" || -z "$S3_KEY_SECRET" ]] && \
                { warn "Bucket, Key-ID und Secret sind Pflicht — bitte erneut eingeben."; continue; }
            RCLONE_REMOTE="s3backup"
            RCLONE_DEST="s3backup:${S3_BUCKET}/${DB_HOSTNAME}"
            ;;
        3)
            read -rp "SFTP Host: " SFTP_HOST
            read -rp "SFTP User: " SFTP_USER
            read -rp "SFTP Pfad-Präfix (z.B. /backups): " SFTP_PATH
            read -rp "SFTP Port [22]: " SFTP_PORT; SFTP_PORT=${SFTP_PORT:-22}
            [[ -z "$SFTP_HOST" || -z "$SFTP_USER" || -z "$SFTP_PATH" ]] && \
                { warn "Host, User und Pfad sind Pflicht — bitte erneut eingeben."; continue; }
            RCLONE_REMOTE="sftpbackup"
            RCLONE_DEST="sftpbackup:${SFTP_PATH}/${DB_HOSTNAME}"
            ;;
        *) warn "Ungültig — Remote-Backup ist Pflicht. Bitte 1, 2 oder 3 wählen." ;;
    esac
    done
fi

info "Remote-Backup-Pfad: ${BOLD}${RCLONE_DEST}${NC}"

echo ""
info "Datenbank-VM wird für ${BOLD}WordPress & WooCommerce${NC} optimiert"
echo ""
confirm_or_die "Einrichtung starten? [j/N]: "

# ── System aktualisieren ───────────────────────────────────────────────────
info "System wird aktualisiert..."
# Robustheit auf frischen cloud-init-VMs: ein evtl. unterbrochenes dpkg heilen
# (z.B. nach hartem Reboot mitten in einer dpkg-Transaktion → "dpkg was interrupted")
# und apt großzügig auf den dpkg-Lock warten lassen (unattended-upgrades hält ihn
# beim ersten Boot, sonst scheitert apt mit einem Lock-Fehler).
dpkg --configure -a 2>/dev/null || true
APT_OPTS=(-o DPkg::Lock::Timeout=300)
apt-get "${APT_OPTS[@]}" update -q
DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" upgrade -yq
DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -yq --no-install-recommends \
    curl wget jq ufw ca-certificates mariadb-server age \
    unattended-upgrades apt-listchanges
log "Pakete installiert"

# ── rclone installieren ───────────────────────────────────────────────────
if [[ -n "$RCLONE_REMOTE" ]]; then
    if command -v rclone &>/dev/null; then
        log "rclone bereits installiert ($(rclone --version 2>/dev/null | head -1))"
    else
        curl -fsS https://rclone.org/install.sh | bash 2>&1 | tail -3
        log "rclone installiert"
    fi

    mkdir -p /root/.config/rclone
    case "$RCLONE_CHOICE" in
        1) cat > /root/.config/rclone/rclone.conf <<EOF

[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_KEY_ID}
secret_access_key = ${R2_KEY_SECRET}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
EOF
            ;;
        2) cat > /root/.config/rclone/rclone.conf <<EOF

[s3backup]
type = s3
provider = AWS
access_key_id = ${S3_KEY_ID}
secret_access_key = ${S3_KEY_SECRET}
region = ${S3_REGION}
${S3_ENDPOINT:+endpoint = ${S3_ENDPOINT}}
acl = private
EOF
            ;;
        3) cat > /root/.config/rclone/rclone.conf <<EOF

[sftpbackup]
type = sftp
host = ${SFTP_HOST}
user = ${SFTP_USER}
port = ${SFTP_PORT}
key_file = /root/.ssh/id_rsa
EOF
            warn "SFTP: SSH-Key /root/.ssh/id_rsa muss manuell auf Ziel-Server hinterlegt werden."
            ;;
    esac
    chmod 600 /root/.config/rclone/rclone.conf
    log "rclone konfiguriert (Remote: ${RCLONE_REMOTE})"
fi

# ── Automatische Sicherheitsupdates ───────────────────────────────────────
cat > /etc/apt/apt.conf.d/50unattended-upgrades-wp <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
log "Automatische Sicherheitsupdates konfiguriert"

# ── Swap ──────────────────────────────────────────────────────────────────
if [[ ! -f /swapfile ]]; then
    TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    if   [[ $TOTAL_RAM_MB -lt 2048 ]];  then SWAP_SIZE="2G"
    elif [[ $TOTAL_RAM_MB -lt 8192 ]];  then SWAP_SIZE="${TOTAL_RAM_MB}M"
    else                                     SWAP_SIZE="4G"
    fi
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10'           >> /etc/sysctl.conf
    sysctl -p &>/dev/null
    log "Swap konfiguriert (${SWAP_SIZE}, swappiness=10)"
else
    warn "Swapfile existiert bereits — übersprungen"
fi

# ── MariaDB konfigurieren ─────────────────────────────────────────────────
# Puffergröße dynamisch an verfügbaren RAM anpassen (50% für InnoDB)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
IB_POOL_MB=$((TOTAL_RAM_MB / 2))
IB_POOL="${IB_POOL_MB}M"

# WICHTIG: Nach mariadb.conf.d/ mit Präfix 99- ablegen, NICHT nach conf.d/.
# my.cnf lädt conf.d/ VOR mariadb.conf.d/ — eine Datei in conf.d/ würde von
# mariadb.conf.d/50-server.cnf (bind-address = 127.0.0.1) wieder überschrieben,
# und MariaDB wäre trotz bind-address = 0.0.0.0 nur auf localhost erreichbar.
cat > /etc/mysql/mariadb.conf.d/99-wordpress-optimized.cnf <<EOF
[mysqld]
# Zeichensatz
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci

# InnoDB — Kernspeicher
innodb_buffer_pool_size       = ${IB_POOL}
innodb_log_file_size          = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method           = O_DIRECT
innodb_read_io_threads        = 4
innodb_write_io_threads       = 4
innodb_file_per_table         = 1
innodb_stats_on_metadata      = 0

# Verbindungen
max_connections               = 200
thread_cache_size             = 20
table_open_cache              = 4096
table_definition_cache        = 2048

# Abfragen
tmp_table_size                = 64M
max_heap_table_size           = 64M
join_buffer_size               = 4M
sort_buffer_size               = 4M
read_buffer_size               = 2M
read_rnd_buffer_size           = 2M

# Query Cache deaktiviert (veraltet, schadet mehr als es nützt)
query_cache_size              = 0
query_cache_type              = 0

# Slow Query Log
slow_query_log                = 1
slow_query_log_file           = /var/log/mysql/slow.log
long_query_time               = 2
log_queries_not_using_indexes = 0

# SSD-Tuning (moderne NVMe/SSD verträgt mehr IOPS)
innodb_io_capacity            = 2000
innodb_io_capacity_max        = 4000

# Große WP-Imports (Migrations, große Mediatheken)
max_allowed_packet            = 256M

# Open-Files (viele Tabellen × file_per_table benötigen viele FDs)
open_files_limit              = 65535

# Netzwerk — lauscht auf allen Interfaces für Remote-Zugriff
bind-address                  = 0.0.0.0
EOF

# systemd-Limits anpassen (sonst greift open_files_limit nicht)
mkdir -p /etc/systemd/system/mariadb.service.d
cat > /etc/systemd/system/mariadb.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=65535
EOF
systemctl daemon-reload
log "MariaDB konfiguriert (InnoDB Buffer: ${IB_POOL})"

# ── MariaDB sichern & Admin-User anlegen ───────────────────────────────────
systemctl restart mariadb

mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

ADMIN_USER="wp_admin"
ADMIN_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32) || true

# Admin-User für jede Web-VM-IP anlegen
IFS=',' read -ra VM_IPS <<< "$WEB_VM_IPS"
for VM_IP in "${VM_IPS[@]}"; do
    VM_IP=$(echo "$VM_IP" | tr -d ' ')
    [[ "$VM_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || err "WEB_VM_IPS: '${VM_IP}' ist keine IPv4-Adresse"
    # Passwort per Heredoc (stdin), nicht per -e — sonst steht es in der argv/Prozessliste.
    mysql <<SQL
CREATE OR REPLACE USER '${ADMIN_USER}'@'${VM_IP}' IDENTIFIED BY '${ADMIN_PASS}';
SQL
    # KEIN 'ALL ON *.*' — das schlösse FILE/SUPER/SHUTDOWN/PROCESS/REPLICATION ein und gäbe
    # einer evtl. kompromittierten Web-VM OS-/Server-Zugriff auf die DB-VM. Stattdessen nur:
    #  - die nötigen globalen Rechte (CREATE DATABASE, CREATE/DROP USER, FLUSH)
    #  - die DB-Level-Rechte (identisch zum Site-User-Set), weitergebbar via GRANT OPTION
    mysql -e "GRANT CREATE, CREATE USER, RELOAD ON *.* TO '${ADMIN_USER}'@'${VM_IP}';"
    mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER ON *.* TO '${ADMIN_USER}'@'${VM_IP}' WITH GRANT OPTION;"
    log "DB-Admin-User für ${VM_IP} angelegt (eingeschränkt — kein FILE/SUPER)"
done
mysql -e "FLUSH PRIVILEGES;"

# ── UFW ────────────────────────────────────────────────────────────────────
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp

for VM_IP in "${VM_IPS[@]}"; do
    VM_IP=$(echo "$VM_IP" | tr -d ' ')
    ufw allow from "$VM_IP" to any port 3306
    log "UFW: MySQL-Zugriff von ${VM_IP} erlaubt"
done

# Netdata streamt OUTBOUND zum Parent; 19999 NICHT weltoffen. Nur für Parent öffnen.
if [[ -n "${NETDATA_PARENT_IP:-}" ]]; then
    ufw allow from "$NETDATA_PARENT_IP" to any port 19999
fi
ufw --force enable
log "Firewall konfiguriert (22, 3306 von Web-VMs${NETDATA_PARENT_IP:+, 19999 nur von ${NETDATA_PARENT_IP}})"

# ── SSH Hardening (per Drop-in — Ubuntu includet sshd_config.d/*.conf zuerst;
#    ein 01-* gewinnt per first-match-wins über 50-cloud-init.conf) ──────────
ask SSH_PUB_KEY "SSH Public Key für ubuntu-User hinterlegen? (leer = überspringen): "
SSH_PUB_KEY="${SSH_PUB_KEY:-}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-wp-hosting-hardening.conf"
{
    echo "PermitRootLogin no"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 20"
    echo "X11Forwarding no"
    echo "AllowTcpForwarding no"
    echo "PubkeyAuthentication yes"
} > "$SSHD_DROPIN"
if [[ -n "$SSH_PUB_KEY" ]] && id ubuntu &>/dev/null; then
    mkdir -p /home/ubuntu/.ssh
    grep -qF "$SSH_PUB_KEY" /home/ubuntu/.ssh/authorized_keys 2>/dev/null \
        || echo "$SSH_PUB_KEY" >> /home/ubuntu/.ssh/authorized_keys
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    echo "PasswordAuthentication no" >> "$SSHD_DROPIN"
    log "SSH Key hinterlegt — Passwort-Login deaktiviert (${SSHD_DROPIN})"
elif [[ -n "$SSH_PUB_KEY" ]]; then
    warn "User 'ubuntu' fehlt — SSH-Key NICHT hinterlegt, Passwort-Login bleibt aktiv (kein Lockout-Risiko)."
else
    warn "Kein SSH Key — Passwort-Login bleibt aktiv"
fi
chmod 644 "$SSHD_DROPIN"
if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || warn "SSH-Neustart fehlgeschlagen"
else
    warn "sshd-Config-Test (sshd -t) fehlgeschlagen — SSH NICHT neu gestartet (Härtung liegt in ${SSHD_DROPIN})."
fi

# ── Netdata ───────────────────────────────────────────────────────────────
# Nur Agent-Install + Loopback-Bind. Parent-Child-Stream-Config kommt zentral über
# proxmox-netdata (configure-netdata-child.sh). Loopback, damit :19999 nicht offen steht.
if systemctl is-active --quiet netdata 2>/dev/null; then
    log "Netdata bereits installiert"
else
    info "Netdata wird installiert..."
    wget -qO /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
    bash /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry 2>&1 | tail -5 || true
    rm -f /tmp/netdata-kickstart.sh
    log "Netdata installiert (Port 19999, Loopback)"
fi
# Web-UI strikt auf Loopback binden (idempotent) — minimales netdata.conf mergt mit Defaults
if command -v netdata &>/dev/null && ! grep -qs "bind socket to IP = 127.0.0.1" /etc/netdata/netdata.conf; then
    mkdir -p /etc/netdata
    cat > /etc/netdata/netdata.conf <<'NDEOF'
[web]
    bind socket to IP = 127.0.0.1
NDEOF
    systemctl restart netdata 2>/dev/null || true
    log "Netdata Web-UI auf 127.0.0.1 gebunden"
fi

# ── MariaDB Backup-Cron ────────────────────────────────────────────────────
mkdir -p /var/backups/mysql
RCLONE_DEST_CFG="${RCLONE_DEST:-}"
cat > /usr/local/bin/mysql-backup.sh <<BEOF
#!/bin/bash
# MariaDB Backup — pro DB ein eigener Dump (selektives Restore möglich)
# Optional: Verschlüsselung mit age wenn /etc/wp-hosting/backup-recipient.txt existiert
set -eo pipefail
BACKUP_DIR="/var/backups/mysql"
DATE=\$(date +%Y%m%d_%H%M)
KEEP_DAYS=7
LOG="/var/log/mysql-backup.log"
RCLONE_DEST="${RCLONE_DEST_CFG}"
ERRORS=0
mkdir -p "\$BACKUP_DIR"

# Slack-Helper laden (notify() postet Backup-Fehler nach Slack; No-Op wenn nicht konfiguriert)
[[ -r /usr/local/lib/wp-hosting-notify.sh ]] && . /usr/local/lib/wp-hosting-notify.sh

# Verschlüsselung aktiv?
RECIPIENT_FILE="/etc/wp-hosting/backup-recipient.txt"
ENCRYPT=false
EXT="sql.gz"
if [[ -f "\$RECIPIENT_FILE" ]] && command -v age &>/dev/null; then
    ENCRYPT=true
    EXT="sql.gz.age"
fi

echo "[\$(date '+%Y-%m-%d %H:%M')] Backup gestartet (encrypt=\$ENCRYPT)" >> "\$LOG"

# Pro DB ein eigener Dump (System-DBs ausschließen)
DB_LIST=\$(mysql -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|mysql|sys)\$' || true)

for DB in \$DB_LIST; do
    OUTFILE="\${BACKUP_DIR}/\${DB}_\${DATE}.\${EXT}"

    if \$ENCRYPT; then
        if mysqldump --single-transaction --quick --lock-tables=false "\$DB" \
            | gzip | age -R "\$RECIPIENT_FILE" -o "\$OUTFILE" 2>/dev/null; then
            SIZE=\$(du -sh "\$OUTFILE" | cut -f1)
            echo "[\$(date '+%Y-%m-%d %H:%M')] OK \${DB} (\${SIZE}, verschlüsselt)" >> "\$LOG"
        else
            echo "[\$(date '+%Y-%m-%d %H:%M')] FEHLER \${DB}" >> "\$LOG"
            ERRORS=\$((ERRORS + 1))
        fi
    else
        if mysqldump --single-transaction --quick --lock-tables=false "\$DB" \
            | gzip > "\$OUTFILE"; then
            SIZE=\$(du -sh "\$OUTFILE" | cut -f1)
            echo "[\$(date '+%Y-%m-%d %H:%M')] OK \${DB} (\${SIZE})" >> "\$LOG"
        else
            echo "[\$(date '+%Y-%m-%d %H:%M')] FEHLER \${DB}" >> "\$LOG"
            ERRORS=\$((ERRORS + 1))
        fi
    fi
done

# Erst lokale Retention durchsetzen (alte Dumps löschen)
# Danach Mirror-Sync → Remote spiegelt Local exakt → 7 Tage auch Remote
find "\$BACKUP_DIR" \( -name "*.sql.gz" -o -name "*.sql.gz.age" \) -mtime +\${KEEP_DAYS} -delete 2>/dev/null || true

# Mirror-Sync: rclone löscht auf Remote was lokal nicht mehr da ist
# → Lokale Retention erzwingt automatisch gleiche Retention auf Remote
if [[ -n "\$RCLONE_DEST" ]] && command -v rclone &>/dev/null; then
    if rclone sync "\$BACKUP_DIR" "\$RCLONE_DEST" \
        --bwlimit "08:00,8M 22:00,off" \
        --transfers 4 --checkers 8 \
        2>>"\$LOG"; then
        REMOTE_COUNT=\$(rclone size "\$RCLONE_DEST" --json 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2 || echo "?")
        echo "[\$(date '+%Y-%m-%d %H:%M')] Remote-Sync OK → \${RCLONE_DEST} (\${REMOTE_COUNT} Dateien)" >> "\$LOG"
    else
        echo "[\$(date '+%Y-%m-%d %H:%M')] Remote-Sync FEHLER" >> "\$LOG"
        ERRORS=\$((ERRORS + 1))
    fi
else
    echo "[\$(date '+%Y-%m-%d %H:%M')] WARNUNG: Remote-Sync übersprungen (RCLONE_DEST nicht konfiguriert)" >> "\$LOG"
    ERRORS=\$((ERRORS + 1))
fi

# Slack-Alarm bei Fehler
if [[ \${ERRORS} -gt 0 ]]; then
    command -v notify >/dev/null 2>&1 && \
        notify "MariaDB-Backup fehlgeschlagen" "\${ERRORS} Dump/Remote-Sync-Fehler — Details: \$LOG"
fi

# Mit Fehleranzahl beenden, damit Cron/Cronicle/Uptime einen kaputten Lauf erkennt
exit "\${ERRORS}"
BEOF
chmod +x /usr/local/bin/mysql-backup.sh
# flock verhindert parallele Läufe bei langlaufenden Dumps
echo "0 2 * * * root /usr/bin/flock -n /var/lock/mysql-backup.lock /usr/local/bin/mysql-backup.sh" > /etc/cron.d/mysql-backup
log "MariaDB Backup-Cron konfiguriert (täglich 02:00, flock-protected → /var/backups/mysql, 7 Tage)"

# ── Slack-Alerts (notify-Helper) + Disk Space Alert Script ─────────────────
mkdir -p /etc/wp-hosting /var/lib/wp-hosting/disk-state

# Slack-Helper installieren — wird von mysql-backup.sh + disk-alert.sh gesourct.
# notify() postet in einen Slack Incoming Webhook (POST JSON {text}); fehlt die
# Webhook-Datei, ist notify() ein No-Op (ein Alarm darf das aufrufende Script nie killen).
cat > /usr/local/lib/wp-hosting-notify.sh <<'NOTIFYEOF'
#!/bin/bash
# Zentrale Slack-Benachrichtigung für die wp-hosting DB-VM-Scripts.
# Wird gesourct (nicht direkt ausgeführt) und stellt notify() bereit.
SLACK_WEBHOOK_FILE="${SLACK_WEBHOOK_FILE:-/etc/wp-hosting/slack-webhook.txt}"

# notify <titel> <details>
notify() {
    local title="${1:-wp-hosting-db}" body="${2:-}"
    [[ -r "$SLACK_WEBHOOK_FILE" ]] || return 0
    local url
    url=$(tr -d '[:space:]' < "$SLACK_WEBHOOK_FILE") || return 0
    [[ -n "$url" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local text
    text=":rotating_light: *${title}* auf \`$(hostname -s)\`"$'\n'"${body}"
    local payload
    payload=$(jq -nc --arg t "$text" '{text: $t}') || return 0
    curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' \
        --data "$payload" "$url" >/dev/null 2>&1 || true
    return 0
}
NOTIFYEOF
chmod 0755 /usr/local/lib/wp-hosting-notify.sh
log "Slack-Helper installiert: /usr/local/lib/wp-hosting-notify.sh"

# Slack Incoming Webhook-URL als Secret ablegen (notify() liest sie dort).
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    printf '%s\n' "$SLACK_WEBHOOK_URL" > /etc/wp-hosting/slack-webhook.txt
    chmod 600 /etc/wp-hosting/slack-webhook.txt
    log "Slack-Webhook hinterlegt — Backup-/Disk-Alerts gehen an Slack"
else
    warn "Keine SLACK_WEBHOOK_URL gesetzt — Alerts bleiben lokal (notify() ist No-Op)"
fi

# Config für manuelle Backup-Tools — db-backup.sh teilt sich diesen Remote mit Auto-Cron
printf 'RCLONE_DEST=%q\n' "${RCLONE_DEST}" > /etc/wp-hosting/db-backup.conf
chmod 600 /etc/wp-hosting/db-backup.conf
log "Manuelle Backup-Tool-Config: /etc/wp-hosting/db-backup.conf"

# age-Recipient für Backup-Verschlüsselung speichern
if [[ -n "${AGE_RECIPIENT:-}" ]]; then
    echo "$AGE_RECIPIENT" > /etc/wp-hosting/backup-recipient.txt
    chmod 644 /etc/wp-hosting/backup-recipient.txt
    log "age Public-Key gespeichert — DB-Backups werden verschlüsselt"
fi

cat > /usr/local/bin/disk-alert.sh <<'ALERTEOF'
#!/bin/bash
# Disk Space Alert — stündlich via Cron
set -euo pipefail

[[ -r /usr/local/lib/wp-hosting-notify.sh ]] || exit 0
. /usr/local/lib/wp-hosting-notify.sh
[[ -r /etc/wp-hosting/slack-webhook.txt ]] || exit 0

THRESHOLD_WARN=80
THRESHOLD_CRIT=90
STATE_DIR="/var/lib/wp-hosting/disk-state"
mkdir -p "$STATE_DIR"

send_webhook() {
    local status="$1" emoji="$2" level="$3" mount="$4" pct="$5" avail="$6"
    notify "Disk ${level}" "${emoji} ${mount} | ${pct}% belegt | ${avail} frei"
}

while IFS= read -r line; do
    mount=$(awk '{print $1}' <<< "$line")
    pct=$(awk '{print $2}' <<< "$line" | tr -d '%')
    avail=$(awk '{print $3}' <<< "$line")
    [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && continue

    state_file="${STATE_DIR}/$(echo "$mount" | tr '/' '_' | tr -d ' ')"
    last=$(cat "$state_file" 2>/dev/null || echo "ok")

    if   [[ $pct -ge $THRESHOLD_CRIT ]]; then
        [[ "$last" != "crit" ]] && send_webhook "down" "🔴" "KRITISCH" "$mount" "$pct" "$avail"
        echo "crit" > "$state_file"
    elif [[ $pct -ge $THRESHOLD_WARN ]]; then
        [[ "$last" == "ok"   ]] && send_webhook "down" "🟡" "WARNUNG"  "$mount" "$pct" "$avail"
        echo "warn" > "$state_file"
    else
        [[ "$last" != "ok"   ]] && send_webhook "up"   "🟢" "OK"       "$mount" "$pct" "$avail"
        echo "ok"   > "$state_file"
    fi
done < <(df --output=target,pcent,avail -h 2>/dev/null | tail -n +2 \
    | grep -Ev "tmpfs|devtmpfs|udev|overlay|squashfs|^/run|^/dev$|^/sys")
ALERTEOF

chmod +x /usr/local/bin/disk-alert.sh
echo "0 * * * * root /usr/local/bin/disk-alert.sh" > /etc/cron.d/disk-alert
[[ -n "${SLACK_WEBHOOK_URL:-}" ]] && log "Disk Space Alert eingerichtet (stündlich, Slack bei >80%/>90%)" || log "Disk Space Alert eingerichtet (kein Slack-Webhook — nur lokal)"

# ── Services starten ───────────────────────────────────────────────────────
systemctl enable mariadb
systemctl restart mariadb
log "MariaDB gestartet"

# ── Zusammenfassung ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Setup abgeschlossen ✓                      ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  DB-Host-IP:    ${BOLD}$(hostname -I | awk '{print $1}')${NC}"
echo ""
echo -e "${BOLD}  Diese Daten bei setup-web.sh eingeben:${NC}"
echo -e "  DB-Admin-User: ${BOLD}${ADMIN_USER}${NC}"
echo -e "  DB-Admin-Pass: ${BOLD}in /etc/wp-hosting/db-credentials.txt${NC} (nicht im Terminal — Scrollback/Mitschnitt)"
echo ""
echo -e "  InnoDB Buffer: ${BOLD}${IB_POOL}${NC}"
echo ""

# Zugangsdaten lokal sichern
mkdir -p /etc/wp-hosting
cat > /etc/wp-hosting/db-credentials.txt <<EOF
DB_HOST=$(hostname -I | awk '{print $1}')
DB_ADMIN_USER=${ADMIN_USER}
DB_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 /etc/wp-hosting/db-credentials.txt
echo -e "  Netdata:       ${BOLD}http://$(hostname -I | awk '{print $1}'):19999${NC}"
echo ""
echo -e "${YELLOW}  → Zugangsdaten gespeichert: /etc/wp-hosting/db-credentials.txt${NC}"
echo -e "${YELLOW}  → Passwort von dort nach 1Password übernehmen (chmod 600, nur root).${NC}"
echo -e "${YELLOW}  → Netdata in Uptime Kuma als Monitor hinzufügen.${NC}"
echo ""
