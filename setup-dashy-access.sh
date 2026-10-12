#!/bin/bash
# Dashy-Zugang auf einer Web-VM einrichten (User, Key, sshd-Match, sudoers, ufw).
# Idempotent, einzeln aufrufbar; setup-web.sh ruft es auf, wenn DASHY_PUB_KEY und
# DASHY_FROM in der Conf gesetzt sind.
#
#   sudo bash setup-dashy-access.sh --pubkey "ssh-ed25519 AAAA… kommentar" --from <ip|cidr>
#
# Ergebnis:
#   - User dashy (bash, kein Passwort, nicht in sudo, nicht in sftpusers)
#   - /etc/ssh/authorized_keys.d/dashy (root 644): restrict,from="<from>" <pubkey>
#   - Match User dashy am Ende von /etc/ssh/sshd_config (kein TTY, kein Forwarding,
#     ForceCommand dashy-gate — keine freie Shell, nur die zwei erlaubten Aufrufe)
#   - /etc/sudoers.d/dashy: dashy-wp als %sftpusers, dashy-sites als root
#   - /usr/local/sbin/dashy-gate (755), dashy-wp (755), dashy-sites (700)
#   - ufw: 22/tcp aus <from>
# Die PVE-Firewall (<vmid>.fw) bleibt Handarbeit — Hinweis am Ende.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -eq 0 ]] || err "Als root ausführen: sudo bash setup-dashy-access.sh …"
TMP_FILES=(); trap 'rm -f "${TMP_FILES[@]}"' EXIT

DASHY_USER="dashy"
PUBKEY=""; FROM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pubkey) PUBKEY="${2:-}"; shift 2 ;;
        --from)   FROM="${2:-}"; shift 2 ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *) err "Unbekannte Option: $1" ;;
    esac
done
[[ -n "$PUBKEY" ]] || err "--pubkey fehlt"
[[ -n "$FROM" ]]   || err "--from fehlt (IP oder CIDR des Dashy-Hosts)"

# ── Eingaben prüfen ─────────────────────────────────────────────────────────
[[ "$FROM" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || err "--from ist keine IPv4-Adresse/CIDR: ${FROM}"
[[ "$PUBKEY" != *$'\n'* ]] || err "--pubkey darf nur eine Zeile sein"
[[ "$PUBKEY" == ssh-ed25519\ * || "$PUBKEY" == ecdsa-sha2-*\ * || "$PUBKEY" == ssh-rsa\ * ]] \
    || err "--pubkey beginnt nicht mit einem Key-Typ (ssh-ed25519 …)"
FINGERPRINT=$(ssh-keygen -lf /dev/stdin <<<"$PUBKEY" 2>/dev/null) || err "--pubkey ist kein gültiger OpenSSH-Public-Key"
log "Public Key gültig: ${FINGERPRINT}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for h in dashy-gate dashy-wp dashy-sites; do
    [[ -f "${SCRIPT_DIR}/${h}" ]] || err "Helfer fehlt neben dem Script: ${SCRIPT_DIR}/${h}"
done
bash -n "${SCRIPT_DIR}/dashy-gate" && bash -n "${SCRIPT_DIR}/dashy-wp" && bash -n "${SCRIPT_DIR}/dashy-sites" || err "Helfer haben Syntaxfehler"
bash "${SCRIPT_DIR}/dashy-wp" --selftest >/dev/null || err "dashy-wp --selftest schlägt fehl"
getent group sftpusers >/dev/null || err "Gruppe sftpusers fehlt — erst setup-web.sh ausführen"

# ── User ───────────────────────────────────────────────────────────────────
if id "$DASHY_USER" &>/dev/null; then
    info "User ${DASHY_USER} existiert"
else
    useradd --create-home --home-dir "/home/${DASHY_USER}" --shell /bin/bash \
        --comment "Dashy management access" "$DASHY_USER"
    log "User ${DASHY_USER} angelegt"
fi
passwd -l "$DASHY_USER" >/dev/null
chmod 750 "/home/${DASHY_USER}"
# Shell-Dotfiles root-eigen: sshd startet das Gate über die Login-Shell, die ~/.bashrc liest
for f in .bashrc .profile .bash_profile .bash_login .bash_logout; do
    [[ -e "/home/${DASHY_USER}/${f}" ]] || : > "/home/${DASHY_USER}/${f}"
    chown root:root "/home/${DASHY_USER}/${f}"; chmod 644 "/home/${DASHY_USER}/${f}"
done
for g in sudo sftpusers; do
    if id -nG "$DASHY_USER" | tr ' ' '\n' | grep -qx "$g"; then
        err "User ${DASHY_USER} ist in Gruppe ${g} — das darf nicht sein, bitte manuell prüfen"
    fi
done
log "User ${DASHY_USER}: Passwort gesperrt, nicht in sudo/sftpusers"

# ── Helfer installieren ────────────────────────────────────────────────────
install -D -m 755 -o root -g root "${SCRIPT_DIR}/dashy-gate"  /usr/local/sbin/dashy-gate
install -D -m 755 -o root -g root "${SCRIPT_DIR}/dashy-wp"    /usr/local/sbin/dashy-wp
install -D -m 700 -o root -g root "${SCRIPT_DIR}/dashy-sites" /usr/local/sbin/dashy-sites
log "Helfer installiert: /usr/local/sbin/dashy-gate (755), dashy-wp (755), dashy-sites (700)"

# ── Authorized Keys (root-eigen, Dashy kann sie nicht ändern) ──────────────
AK_DIR="/etc/ssh/authorized_keys.d"; AK_FILE="${AK_DIR}/${DASHY_USER}"
install -d -m 755 -o root -g root "$AK_DIR"
TMP_FILES+=("${AK_FILE}.tmp")
printf 'restrict,command="/usr/local/sbin/dashy-gate",from="%s" %s\n' "$FROM" "$PUBKEY" > "${AK_FILE}.tmp"
chmod 644 "${AK_FILE}.tmp"; chown root:root "${AK_FILE}.tmp"
mv -f "${AK_FILE}.tmp" "$AK_FILE"
log "Key hinterlegt: ${AK_FILE} (restrict, command=dashy-gate, from=${FROM})"

# ── sshd: Match User dashy ans Ende der sshd_config (wie der SFTP-Block) ──
SSH_CONFIG="/etc/ssh/sshd_config"
if ! grep -q "^Match User ${DASHY_USER}\$" "$SSH_CONFIG"; then
    cat >> "$SSH_CONFIG" <<SSHEOF

# ── Dashy (Management-Dashboard): Key-only, kein TTY, kein Forwarding ──────
Match User ${DASHY_USER}
    AuthorizedKeysFile ${AK_FILE}
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    ForceCommand /usr/local/sbin/dashy-gate
SSHEOF
    log "Match User ${DASHY_USER} an ${SSH_CONFIG} angehängt"
else
    info "Match User ${DASHY_USER} existiert bereits in ${SSH_CONFIG}"
fi
sshd -t || err "sshd -t schlägt fehl — sshd NICHT neu geladen, Config prüfen!"
# Harte Prüfung der effektiven Konfiguration für dashy (nicht nur anzeigen)
SSHD_EFF=$(sshd -T -C "user=${DASHY_USER},host=dashy,addr=${FROM%%/*}" 2>/dev/null)
for want in "forcecommand /usr/local/sbin/dashy-gate" "authorizedkeysfile ${AK_FILE}" "permittty no" \
            "allowagentforwarding no" "allowtcpforwarding no" "passwordauthentication no"; do
    grep -qix "$want" <<<"$SSHD_EFF" || err "sshd -T für ${DASHY_USER}: '${want}' fehlt — Match-Block in ${SSH_CONFIG} prüfen (alter Block ohne ForceCommand?)"
done
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "sshd-Reload fehlgeschlagen"
log "sshd-Config geprüft (ForceCommand, kein TTY, kein Forwarding) und neu geladen"

# ── sudoers ────────────────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/${DASHY_USER}"
SUDOERS_TMP=$(mktemp /etc/sudoers.d/.dashy.XXXXXX); TMP_FILES+=("$SUDOERS_TMP")
cat > "$SUDOERS_TMP" <<SUDOEOF
# Dashy: Read-only wp-cli als Site-User, Registry als root. Verwaltet von setup-dashy-access.sh
${DASHY_USER} ALL=(%sftpusers) NOPASSWD: /usr/local/sbin/dashy-wp
${DASHY_USER} ALL=(root) NOPASSWD: /usr/local/sbin/dashy-sites
SUDOEOF
chmod 440 "$SUDOERS_TMP"; chown root:root "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null || { rm -f "$SUDOERS_TMP"; err "sudoers-Syntax ungültig — nichts geändert"; }
mv -f "$SUDOERS_TMP" "$SUDOERS_FILE"
log "sudoers: ${SUDOERS_FILE}"

# ── ufw ────────────────────────────────────────────────────────────────────
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ufw status | grep -E '^22/tcp\s+ALLOW IN\s+' | grep -qw "$FROM"; then
        info "ufw: 22/tcp aus ${FROM} bereits erlaubt"
    else
        ufw allow from "$FROM" to any port 22 proto tcp comment "ssh dashy" >/dev/null
        log "ufw: 22/tcp aus ${FROM} erlaubt"
    fi
else
    warn "ufw nicht aktiv — Port 22 aus ${FROM} nicht geöffnet"
fi

# ── Selbstprüfung ──────────────────────────────────────────────────────────
echo ""
info "sudo -l für ${DASHY_USER}:"
sudo -n -u "$DASHY_USER" sudo -n -l 2>/dev/null | sed -n '/may run/,$p' | sed 's/^/    /'
info "sshd -T für ${DASHY_USER} aus ${FROM%%/*}:"
sshd -T -C "user=${DASHY_USER},host=dashy,addr=${FROM%%/*}" 2>/dev/null \
    | grep -iE '^(authorizedkeysfile|permittty|allowagentforwarding|allowtcpforwarding|passwordauthentication|forcecommand)' | sed 's/^/    /'
echo ""
log "Dashy-Zugang eingerichtet."
warn "PVE-Firewall nicht vergessen: in /etc/pve/firewall/<vmid>.fw eine IN-Regel ACCEPT tcp dport 22 source ${FROM}"
info "Test vom Dashy-Host:  ssh ${DASHY_USER}@<vm-ip> sudo -n /usr/local/sbin/dashy-sites"
info "                      ssh ${DASHY_USER}@<vm-ip> sudo -n -u <siteuser> /usr/local/sbin/dashy-wp <domain> core version"
