#!/usr/bin/env bash
# new-company-lab.sh — Instancie ou supprime un lab CSNx (Server + Client + Firewall
# Stormshield) pour une compagnie donnée, à partir des images maîtres qcow2.
# "CSNx" est générique : ce même lab sert pour plusieurs formations Stormshield
# (CSNA, CSNE, CSNR, CSNTS, ...), d'où le nommage des réseaux en CSNx plutôt qu'en CSNA.
#
# Usage :
#   ./new-company-lab.sh <LETTRE> [numero]        crée une instance de compagnie
#   ./new-company-lab.sh <LETTRE> --remove        supprime ses VM + disques (garde les réseaux)
#   ./new-company-lab.sh <LETTRE> --remove-all    supprime ses VM + disques ET ses réseaux
#   Ajoute -y (ou --yes) à une suppression pour ne pas demander de confirmation.
#
#   LETTRE  : lettre de compagnie A-Z (ex: B)
#   numero  : optionnel (création uniquement), sinon calculé depuis la lettre (A=1, B=2, ...)
#
# Voir PROCEDURE.md dans ce même dossier pour le détail des étapes et les mises en garde.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <LETTRE A-Z> [numero]" >&2
  echo "       $0 <LETTRE A-Z> --remove|--remove-all [-y]" >&2
  exit 1
fi

LETTER=$(echo "$1" | tr '[:lower:]' '[:upper:]')
if ! [[ "$LETTER" =~ ^[A-Z]$ ]]; then
  echo "Erreur: la lettre de compagnie doit être une seule lettre A-Z (reçu: $1)" >&2
  exit 1
fi
shift

ACTION="create"
NUM_OVERRIDE=""
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --remove) ACTION="remove" ;;
    --remove-all) ACTION="remove-all" ;;
    -y|--yes) ASSUME_YES=1 ;;
    [0-9]*) NUM_OVERRIDE="$arg" ;;
    *)
      echo "Argument inconnu: $arg" >&2
      exit 1
      ;;
  esac
done

# A=1, B=2, ... calculé depuis le code ASCII, sauf si un numéro explicite est donné
if [ -n "$NUM_OVERRIDE" ]; then
  NUM="$NUM_OVERRIDE"
else
  NUM=$(( $(printf '%d' "'$LETTER") - 64 ))
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTERS_DIR="$SCRIPT_DIR/masters"
IMAGES_DIR=/var/lib/libvirt/images
IN_NET="LAN-${LETTER}-CSNx"     # = réseau "net-in" du schéma d'adressage (IN 192.168.<num>.0/24)
DMZ_NET="DMZ-${LETTER}-CSNx"    # = réseau "net-dmz" du schéma d'adressage (DMZ 172.16.<num>.0/24)
IN_SUBNET="192.168.${NUM}"
DMZ_SUBNET="172.16.${NUM}"

SERVER_NAME="CSNx-Server-${LETTER}"
CLIENT_NAME="CSNx-Client-${LETTER}"
FIREWALL_NAME="CSNx-SNS-Firewall-${LETTER}"

# Images maîtres en lecture seule, dans le dossier du projet (jamais dans /var/lib/libvirt/images)
SERVER_MASTER="$MASTERS_DIR/CSNx-Server.qcow2"
CLIENT_MASTER="$MASTERS_DIR/CSNx-Client.qcow2"
FIREWALL_MASTER="$MASTERS_DIR/CSNx-SNS-Firewall.qcow2"

# Disques d'instance (overlay qcow2) : dans le pool libvirt standard, comme toutes les autres VM
SERVER_DISK="$IMAGES_DIR/${SERVER_NAME}.qcow2"
CLIENT_DISK="$IMAGES_DIR/${CLIENT_NAME}.qcow2"
FIREWALL_DISK="$IMAGES_DIR/${FIREWALL_NAME}.qcow2"

# MAC canoniques réutilisées telles quelles (réseaux isolés par compagnie -> pas de collision possible)
SERVER_MAC="08:00:27:79:b6:44"
CLIENT_MAC="08:00:27:11:07:b7"
FW_LAN_MAC="08:00:27:0e:f2:06"
FW_DMZ_MAC="08:00:27:b2:e7:80"
# La carte WAN du firewall sort sur le réseau 'default' PARTAGÉ par toutes les compagnies :
# MAC dérivée du numéro pour rester unique par instance.
FW_WAN_MAC=$(printf '52:54:00:c5:9a:%02x' "$NUM")

# =========================================================================
# Suppression (--remove / --remove-all)
# =========================================================================

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  read -r -p "$prompt [o/N] " reply
  case "$reply" in
    o|O|oui|Oui|OUI|y|Y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

remove_vm() {
  local name="$1" disk="$2"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    # On tente destroy sans pré-vérifier l'état : virsh renvoie juste une erreur
    # inoffensive si la VM était déjà arrêtée, qu'on ignore avec "|| true". Pré-vérifier
    # via "virsh domstate | grep" est fragile (SIGPIPE possible sur le pipe si grep sort
    # dès qu'il trouve son match, avant que virsh ait fini d'écrire -> avec "pipefail" le
    # statut de la pipeline reflète ce SIGPIPE, pas le résultat réel du grep -> faux négatif).
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" >/dev/null
    echo "VM $name : supprimée."
  else
    echo "VM $name : déjà absente."
  fi
  if [ -f "$disk" ]; then
    rtk proxy sudo rm -f "$disk"
    echo "Disque $disk : supprimé."
  else
    echo "Disque $disk : déjà absent."
  fi
}

remove_net() {
  local name="$1"
  if virsh net-info "$name" >/dev/null 2>&1; then
    # Même remarque que dans remove_vm : pas de pré-check "Active" via grep sur une pipe,
    # on tente destroy directement et on ignore l'erreur si le réseau était déjà arrêté.
    virsh net-destroy "$name" >/dev/null 2>&1 || true
    virsh net-undefine "$name" >/dev/null
    echo "Réseau $name : supprimé."
  else
    echo "Réseau $name : déjà absent."
  fi
}

if [ "$ACTION" = "remove" ] || [ "$ACTION" = "remove-all" ]; then
  echo "=== Suppression — compagnie ${LETTER} ==="
  echo "VM + disques concernés : $SERVER_NAME, $CLIENT_NAME, $FIREWALL_NAME"
  if [ "$ACTION" = "remove-all" ]; then
    echo "Réseaux également supprimés : $IN_NET, $DMZ_NET"
  else
    echo "Réseaux $IN_NET / $DMZ_NET conservés (utilise --remove-all pour aussi les supprimer)."
  fi
  echo
  if ! confirm "Confirmer la suppression ?"; then
    echo "Annulé."
    exit 0
  fi
  echo

  remove_vm "$SERVER_NAME" "$SERVER_DISK"
  remove_vm "$CLIENT_NAME" "$CLIENT_DISK"
  remove_vm "$FIREWALL_NAME" "$FIREWALL_DISK"

  if [ "$ACTION" = "remove-all" ]; then
    remove_net "$IN_NET"
    remove_net "$DMZ_NET"
  fi

  echo
  echo "=== Terminé ==="
  exit 0
fi

# =========================================================================
# Création (comportement par défaut, inchangé)
# =========================================================================

echo "=== Lab CSNx — compagnie ${LETTER} (numéro ${NUM}) ==="
echo "Réseau IN  (${IN_NET})  : ${IN_SUBNET}.0/24"
echo "Réseau DMZ (${DMZ_NET}) : ${DMZ_SUBNET}.0/24"
echo "WAN firewall MAC        : ${FW_WAN_MAC} (sur le réseau 'default')"
echo

for master in "$SERVER_MASTER" "$CLIENT_MASTER" "$FIREWALL_MASTER"; do
  if [ ! -f "$master" ]; then
    echo "Erreur: image maître introuvable: $master" >&2
    exit 1
  fi
done

if virsh dominfo "$SERVER_NAME" >/dev/null 2>&1; then
  echo "Erreur: la VM $SERVER_NAME existe déjà. Supprime-la d'abord (--remove) si tu veux la recréer." >&2
  exit 1
fi

# --- 1. Réseaux ---------------------------------------------------------
create_net() {
  local name="$1" subnet="$2"
  if virsh net-info "$name" >/dev/null 2>&1; then
    echo "Réseau $name déjà présent, on le garde tel quel."
    return
  fi
  local xml="/tmp/${name}.xml"
  cat > "$xml" <<EOF
<network>
  <name>${name}</name>
  <bridge stp='on' delay='0'/>
  <domain name='${name}'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${subnet}.128' end='${subnet}.253'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$xml"
  virsh net-start "$name"
  virsh net-autostart "$name"
  echo "Réseau $name créé (${subnet}.0/24)."
}

create_net "$IN_NET" "$IN_SUBNET"
create_net "$DMZ_NET" "$DMZ_SUBNET"

# --- 2. Disques (clones légers, backing file = image maître) -----------
echo
echo "Création des disques (overlay qcow2, image maître jamais modifiée)..."
rtk proxy sudo qemu-img create -f qcow2 -F qcow2 -b "$SERVER_MASTER" "$SERVER_DISK"
rtk proxy sudo qemu-img create -f qcow2 -F qcow2 -b "$CLIENT_MASTER" "$CLIENT_DISK"
rtk proxy sudo qemu-img create -f qcow2 -F qcow2 -b "$FIREWALL_MASTER" "$FIREWALL_DISK"
rtk proxy sudo chown root:root "$SERVER_DISK" "$CLIENT_DISK" "$FIREWALL_DISK"
rtk proxy sudo chmod 600 "$SERVER_DISK" "$CLIENT_DISK" "$FIREWALL_DISK"

# --- 3. Définition des 3 domaines ---------------------------------------
echo "Définition des VM..."

cat > "/tmp/${SERVER_NAME}.xml" <<EOF
<domain type='kvm'>
  <name>${SERVER_NAME}</name>
  <description>Instance compagnie ${LETTER} (numéro ${NUM}) — clonée depuis l'image maître CSNx-Server.qcow2 le $(date -I). Identifiants : user/user ou root/root. Voir PROCEDURE.md.</description>
  <memory unit='KiB'>98304</memory>
  <currentMemory unit='KiB'>98304</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-noble'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-model' check='partial'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${SERVER_DISK}'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <controller type='scsi' index='0' model='lsilogic'/>
    <controller type='pci' index='0' model='pci-root'/>
    <interface type='network'>
      <mac address='${SERVER_MAC}'/>
      <source network='${DMZ_NET}'/>
      <model type='e1000'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'><model name='isa-serial'/></target></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>
    <video><model type='cirrus' vram='9216' heads='1' primary='yes'/></video>
    <memballoon model='none'/>
  </devices>
</domain>
EOF

cat > "/tmp/${CLIENT_NAME}.xml" <<EOF
<domain type='kvm'>
  <name>${CLIENT_NAME}</name>
  <description>Instance compagnie ${LETTER} (numéro ${NUM}) — clonée depuis l'image maître CSNx-Client.qcow2 le $(date -I). Identifiants : user/user. Voir PROCEDURE.md.</description>
  <memory unit='KiB'>3145728</memory>
  <currentMemory unit='KiB'>3145728</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-noble'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-model' check='partial'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${CLIENT_DISK}'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <controller type='scsi' index='0' model='lsilogic'/>
    <controller type='pci' index='0' model='pci-root'/>
    <interface type='network'>
      <mac address='${CLIENT_MAC}'/>
      <source network='${IN_NET}'/>
      <model type='e1000'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'><model name='isa-serial'/></target></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <input type='tablet' bus='usb'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>
    <video><model type='cirrus' vram='16384' heads='1' primary='yes'/></video>
    <memballoon model='none'/>
  </devices>
</domain>
EOF

cat > "/tmp/${FIREWALL_NAME}.xml" <<EOF
<domain type='kvm'>
  <name>${FIREWALL_NAME}</name>
  <description>Instance compagnie ${LETTER} (numéro ${NUM}) — clonée depuis l'image maître CSNx-SNS-Firewall.qcow2 le $(date -I). Disque en virtio-blk (obligatoire, voir PROCEDURE.md). MAC WAN générée pour cette instance: ${FW_WAN_MAC}. Identifiants : admin/admin. 1 vCPU / 2 Go RAM max : licence pédagogique Stormshield EVA1 (ne pas augmenter).</description>
  <memory unit='KiB'>1024000</memory>
  <currentMemory unit='KiB'>1024000</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-noble'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-model' check='partial'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${FIREWALL_DISK}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <controller type='pci' index='0' model='pci-root'/>
    <interface type='network'>
      <mac address='${FW_WAN_MAC}'/>
      <source network='default'/>
      <model type='e1000'/>
    </interface>
    <interface type='network'>
      <mac address='${FW_LAN_MAC}'/>
      <source network='${IN_NET}'/>
      <model type='e1000'/>
    </interface>
    <interface type='network'>
      <mac address='${FW_DMZ_MAC}'/>
      <source network='${DMZ_NET}'/>
      <model type='e1000'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'><model name='isa-serial'/></target></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>
    <video><model type='cirrus' vram='9216' heads='1' primary='yes'/></video>
    <memballoon model='none'/>
  </devices>
</domain>
EOF

virsh define "/tmp/${SERVER_NAME}.xml"
virsh define "/tmp/${CLIENT_NAME}.xml"
virsh define "/tmp/${FIREWALL_NAME}.xml"

echo
echo "=== Terminé ==="
echo "VM définies (pas démarrées) : $SERVER_NAME, $CLIENT_NAME, $FIREWALL_NAME"
echo "Démarre-les dans cet ordre : virsh start $SERVER_NAME ; virsh start $FIREWALL_NAME ; virsh start $CLIENT_NAME"
echo "Puis suis les étapes « premier démarrage » de PROCEDURE.md (sélection de compagnie, etc.)."
