#!/bin/bash
# Erstellt ein Ubuntu 24.04 Cloud-init Template in Proxmox
# Ausführen auf dem Proxmox-Host als root

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."
command -v qm &>/dev/null || err "qm nicht gefunden — Script muss auf dem Proxmox-Host laufen."

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Proxmox Template erstellen                 ║"
echo "║   Ubuntu 24.04 LTS Cloud-init                ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Konfiguration abfragen ─────────────────────────────────────────────────
read -rp "Template-VM-ID [Standard: 9000]: " TEMPLATE_ID
TEMPLATE_ID=${TEMPLATE_ID:-9000}

# VMID muss clusterweit eindeutig sein: pmxcfs (/etc/pve) ist clusterweit gemountet, 'qm status'
# sieht dagegen nur den lokalen Node — eine Kollision auf einem anderen Node fiele sonst erst beim
# 'qm create' auf. VM- und CT-IDs teilen denselben Namespace, daher beide Verzeichnisse prüfen.
shopt -s nullglob
_EXISTING_CONF=( /etc/pve/nodes/*/qemu-server/"${TEMPLATE_ID}".conf /etc/pve/nodes/*/lxc/"${TEMPLATE_ID}".conf )
shopt -u nullglob
if (( ${#_EXISTING_CONF[@]} > 0 )); then
    err "VM-/CT-ID ${TEMPLATE_ID} existiert bereits im Cluster (${_EXISTING_CONF[0]}). Andere ID wählen oder bestehende VM/CT löschen."
fi

read -rp "vCPU Anzahl [Standard: 2]: " TEMPLATE_CORES
TEMPLATE_CORES=${TEMPLATE_CORES:-2}
[[ ! "$TEMPLATE_CORES" =~ ^[0-9]+$ ]] && err "Ungültige CPU-Anzahl."

read -rp "RAM in MB [Standard: 2048]: " TEMPLATE_RAM
TEMPLATE_RAM=${TEMPLATE_RAM:-2048}
[[ ! "$TEMPLATE_RAM" =~ ^[0-9]+$ ]] && err "Ungültiger RAM-Wert."

echo -e "${YELLOW}  Tipp: Disk klein halten (≤ kleinste VM-Disk), da Proxmox beim Klonen nicht verkleinern kann.${NC}"
read -rp "Disk-Größe in GB [Standard: 10]: " TEMPLATE_DISK
TEMPLATE_DISK=${TEMPLATE_DISK:-10}
[[ ! "$TEMPLATE_DISK" =~ ^[0-9]+$ ]] && err "Ungültiger Disk-Wert."

# Verfügbare Storages anzeigen
echo ""
info "Verfügbare Storages:"
mapfile -t STORAGE_LIST < <(pvesm status | awk 'NR>1 {print $1}')
for i in "${!STORAGE_LIST[@]}"; do
    TYPE=$(pvesm status | awk -v name="${STORAGE_LIST[$i]}" '$1==name {print $2}')
    printf "  %d) %s (%s)\n" "$((i+1))" "${STORAGE_LIST[$i]}" "$TYPE"
done
echo ""
read -rp "Storage für Template [Nummer oder Name]: " STORAGE_INPUT
if [[ "$STORAGE_INPUT" =~ ^[0-9]+$ ]] && \
   [[ "$STORAGE_INPUT" -ge 1 ]] && \
   [[ "$STORAGE_INPUT" -le "${#STORAGE_LIST[@]}" ]]; then
    STORAGE="${STORAGE_LIST[$((STORAGE_INPUT-1))]}"
else
    STORAGE="${STORAGE_INPUT:-local-lvm}"
fi
info "Storage: ${BOLD}${STORAGE}${NC}"

read -rp "Netzwerk-Bridge [Standard: vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

# SSH Root Passwort generieren
ROOT_SSH_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 24) || true

echo ""
info "Template-ID: ${BOLD}${TEMPLATE_ID}${NC}"
info "vCPU:        ${BOLD}${TEMPLATE_CORES}${NC}"
info "RAM:         ${BOLD}${TEMPLATE_RAM} MB${NC}"
info "Disk:        ${BOLD}${TEMPLATE_DISK} GB${NC}"
info "Storage:     ${BOLD}${STORAGE}${NC}"
info "Bridge:      ${BOLD}${BRIDGE}${NC}"
echo ""
read -rp "Template erstellen? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Ubuntu 24.04 Cloud Image herunterladen ─────────────────────────────────
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_FILE="/tmp/ubuntu-24.04-cloud.img"

if [[ -f "$IMG_FILE" ]]; then
    warn "Image bereits vorhanden — wird wiederverwendet."
else
    info "Ubuntu 24.04 Cloud Image wird heruntergeladen..."
    wget -q --show-progress "$IMG_URL" -O "$IMG_FILE"
    log "Image heruntergeladen"
fi

# ── VM erstellen ──────────────────────────────────────────────────────────
info "VM ${TEMPLATE_ID} wird erstellt..."

qm create "$TEMPLATE_ID" \
    --name "ubuntu-2404-template" \
    --memory "$TEMPLATE_RAM" \
    --cores "$TEMPLATE_CORES" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1" \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --onboot 0

# Cloud Image als Disk importieren
info "Disk wird importiert..."
qm importdisk "$TEMPLATE_ID" "$IMG_FILE" "$STORAGE"
# Disk-Name dynamisch aus VM-Konfig lesen — Name variiert je nach Storage-Typ
IMPORTED_DISK=$(qm config "$TEMPLATE_ID" | grep "^unused0:" | awk '{print $2}')
[[ -z "$IMPORTED_DISK" ]] && err "Importierte Disk nicht gefunden — bitte manuell prüfen."
qm set "$TEMPLATE_ID" --scsi0 "${IMPORTED_DISK},cache=writethrough,discard=on,ssd=1"

# Cloud-init Drive
qm set "$TEMPLATE_ID" --ide2 "${STORAGE}:cloudinit"

# Boot von der Disk
qm set "$TEMPLATE_ID" --boot order=scsi0

# Cloud-init: Proxmox generiert User-Daten (ubuntu-User + Passwort)
# vendor= ergänzt nur — überschreibt --cipassword NICHT (im Gegensatz zu user=)
qm set "$TEMPLATE_ID" \
    --citype nocloud \
    --ciuser ubuntu \
    `# cipassword vorgehasht: argv und PVE-Tasklog zeigen nur den Hash; PVE 9 reicht $6$ unverändert durch` \
    --cipassword "$(printf '%s\n' "$ROOT_SSH_PASS" | openssl passwd -6 -stdin)" \
    --ipconfig0 "ip=dhcp"

# Vendor-Daten: SSH-Passwort-Login aktivieren (läuft zusätzlich zu Proxmox-User-Daten)
# 'snippets' auf Storage 'local' sicherstellen — ein frisches PVE hat den Content-Type nicht,
# --cicustom vendor=local:snippets/... schlägt dann fehl.
if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx local; then
    info "Storage 'local' unterstützt noch keine Snippets — wird ergänzt."
    LOCAL_CONTENT=$(awk '/^dir: local$/{f=1;next} f&&/^[[:space:]]+content[[:space:]]/{sub(/^[[:space:]]+content[[:space:]]+/,"");print;exit} f&&/^[^[:space:]]/{exit}' /etc/pve/storage.cfg)
    pvesm set local --content "${LOCAL_CONTENT:+${LOCAL_CONTENT},}snippets"
    log "Snippets auf 'local' aktiviert (${LOCAL_CONTENT:-leer} + snippets)"
fi
mkdir -p /var/lib/vz/snippets
cat > /var/lib/vz/snippets/vm-vendor.yaml <<'EOF'
#cloud-config
ssh_pwauth: true
disable_root: false
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
EOF
qm set "$TEMPLATE_ID" --cicustom "vendor=local:snippets/vm-vendor.yaml"

# Disk vergrößern
qm resize "$TEMPLATE_ID" scsi0 "${TEMPLATE_DISK}G"

log "VM ${TEMPLATE_ID} konfiguriert"

# ── In Template umwandeln ─────────────────────────────────────────────────
qm template "$TEMPLATE_ID"
log "Template erstellt: ubuntu-2404-template (ID: ${TEMPLATE_ID})"

# Temporäres Image entfernen
rm -f "$IMG_FILE"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Template fertig ✓                          ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Template-ID:     ${BOLD}${TEMPLATE_ID}${NC}"
echo -e "  vCPU:            ${BOLD}${TEMPLATE_CORES}${NC}"
echo -e "  RAM:             ${BOLD}${TEMPLATE_RAM} MB${NC}"
echo -e "  Disk:            ${BOLD}${TEMPLATE_DISK} GB${NC}"
echo -e "  Storage:         ${BOLD}${STORAGE}${NC}"
echo ""
# Cloud-Init-Passwort nicht ins Terminal (Scrollback/Mitschnitt), sondern in eine 600-Datei
# auf dem PVE-Host; von dort nach 1Password übernehmen.
_CI_FILE="/root/.wp-hosting/template-${TEMPLATE_ID}-cipassword.txt"
mkdir -p /root/.wp-hosting; chmod 700 /root/.wp-hosting
( umask 077; printf 'TEMPLATE_ID=%s\nSSH_USER=ubuntu\nSSH_PASS=%s\n' "$TEMPLATE_ID" "$ROOT_SSH_PASS" > "$_CI_FILE" ); chmod 600 "$_CI_FILE"   # umask greift nicht bei vorhandener Datei (ID-Wiederverwendung)
echo -e "${BOLD}  SSH-Passwort (User: ubuntu): in ${_CI_FILE}${NC} (nicht im Terminal)"
echo ""
echo -e "${YELLOW}  → Passwort von dort nach 1Password (cloud-init setzt es für 'ubuntu', nicht root)${NC}"
echo -e "${YELLOW}  → Nächster Schritt:${NC}"
echo ""
echo "     curl -sO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/proxmox-create-vm.sh"
echo "     bash proxmox-create-vm.sh"
echo ""
