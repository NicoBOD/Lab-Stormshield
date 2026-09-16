# Procédure — Lab CSNx Stormshield sous QEMU/KVM/libvirt

Dernière mise à jour : 2026-09-09. Écrit après conversion de l'OVA `CSNx-v4.8-LAB-PLATFORM.ova`
(export VirtualBox 7.2.4) en trois VM QEMU/KVM sur `pc-fixe`. Stack utilisée : QEMU/KVM + libvirt +
virt-manager, réseau `default` (NAT) déjà présent sur l'hôte.

« CSNx » est générique à dessein : ce même lab (Server + Client + Firewall Stormshield) sert de base
à plusieurs formations Stormshield (CSNA, CSNE, CSNR, CSNTS...), d'où des réseaux/VM nommés `CSNx`
plutôt que d'après une formation en particulier.

## 1. Vue d'ensemble

Le lab CSNx comprend 3 VM reliées entre elles :

```
                    Internet (réel)
                         │
                    réseau 'default' (NAT, DHCP)
                         │
                  ┌──────┴──────┐
                  │  Firewall   │  out (WAN) - in (LAN) - dmz1 (DMZ)
                  │ Stormshield │
                  └──┬───────┬──┘
                     │       │
        LAN-<X>-CSNx │       │ DMZ-<X>-CSNx
        192.168.y.0/24       172.16.y.0/24
                     │       │
              ┌──────┴─┐   ┌─┴────────┐
              │ Client │   │  Server  │
              │(Alpine)│   │ (Debian) │
              └────────┘   └──────────┘
```

Chaque **compagnie** (= un lab isolé pour un binôme/étudiant/session) est identifiée par une lettre
(A, B, C...) et un numéro correspondant (1, 2, 3... — A=1, B=2, etc.). Ce numéro sert dans les deux
sous-réseaux privés de cette compagnie :

| Réseau | Rôle | Sous-réseau | Convention de nommage libvirt |
|---|---|---|---|
| IN  | LAN (côté client) | `192.168.<numéro>.0/24` | `LAN-<LETTRE>-CSNx` |
| DMZ | DMZ (côté serveur) | `172.16.<numéro>.0/24` | `DMZ-<LETTRE>-CSNx` |

Le WAN de chaque firewall sort directement sur Internet via le réseau libvirt **`default`** (NAT,
IP dynamique) — ce réseau est **partagé par toutes les compagnies simultanément**.

## 2. Images maîtres — masters purs, en lecture seule

Trois images qcow2, converties depuis l'OVA, servent de référence. Elles vivent dans ce dossier de
projet (pas dans le pool libvirt) et sont en lecture seule (`chmod 444`, propriétaire `user`) :

| Fichier | VM d'origine | OS | Bus disque |
|---|---|---|---|
| `masters/CSNx-Server.qcow2` | CSNx-Server | Debian 5.0 Lenny i386 | SCSI/lsilogic |
| `masters/CSNx-Client.qcow2` | CSNx-Client | Alpine Linux 3.20 x86_64 | SCSI/lsilogic |
| `masters/CSNx-SNS-Firewall.qcow2` | CSNx-SNS-Firewall | Stormshield SNS 4.8.14 (FreeBSD) | **virtio-blk** |

Aucune VM ne pointe directement dessus — les VM `CSNx-Server`, `CSNx-Client` et
`CSNx-SNS-Firewall` (sans suffixe de lettre) qui existaient avant ont été supprimées (`virsh
undefine`) le 2026-09-09 pour lever toute ambiguïté. **Toute instance de compagnie, y compris A,
passe par `new-company-lab.sh` et un clone** (overlay qcow2 avec fichier de sauvegarde = image
maître). Testé de bout en bout le 2026-09-09 : `./new-company-lab.sh A` a recréé une compagnie A
propre (`CSNx-Server-A`, `CSNx-Client-A`, `CSNx-SNS-Firewall-A`), démarrée et vérifiée fonctionnelle
(mêmes écrans qu'à la conversion initiale, réseau DMZ répondant au ping). Le fait que les images
maîtres vivent hors de `/var/lib/libvirt/images` ne pose pas de problème d'AppArmor — libvirt suit la
chaîne de fichiers de sauvegarde du qcow2 quel que soit son emplacement réel.

Ne jamais faire `chmod` en écriture sur les fichiers de `masters/` tant qu'ils servent de référence.
Une réinstallation propre se ferait en réextrayant les disques depuis
`/home/user/Temp/CSNx-v4.8-LAB-PLATFORM.ova` (voir historique de conversion, pas détaillé ici).

## 3. Créer une nouvelle instance de compagnie

Le script `new-company-lab.sh` (dans ce même dossier) automatise la création des réseaux + le
clonage léger des 3 disques (overlay qcow2 avec fichier de sauvegarde = image maître, quasi
instantané et n'utilise que quelques centaines de Ko tant que rien n'est écrit) + la définition des
3 VM. **Testé de bout en bout le 2026-09-09** avec la compagnie A (réseaux réutilisés proprement,
disques clonés, 3 VM démarrées et vérifiées fonctionnelles — voir §2). Idempotent sur les réseaux :
relancer le script pour une compagnie dont les réseaux existent déjà les laisse intacts.

```bash
cd /home/user/Documents/CSNx-Stormshield-Lab
./new-company-lab.sh B          # crée la compagnie B (numéro 2 déduit automatiquement)
./new-company-lab.sh D 4        # équivalent, numéro explicite
```

Le même script gère aussi la suppression (`--remove` / `--remove-all`, voir §5).

Ce que fait le script :
1. Vérifie que les images maîtres existent et qu'aucune VM du même nom n'existe déjà.
2. Crée (si absents) les réseaux `LAN-<X>-CSNx` (192.168.y.0/24) et `DMZ-<X>-CSNx` (172.16.y.0/24),
   hôte en `.1`, DHCP `.128`–`.253` (`.254` volontairement laissée libre pour l'interface du
   firewall sur chaque segment).
3. Crée 3 disques overlay : `CSNx-{Server,Client,SNS-Firewall}-<LETTRE>.qcow2`.
4. Définit les 3 VM (`CSNx-Server-<LETTRE>`, `CSNx-Client-<LETTRE>`, `CSNx-SNS-Firewall-<LETTRE>`)
   avec le matériel virtuel qui a fonctionné le 2026-09-09 (voir tableau de référence §6).
5. La carte WAN du firewall reçoit une MAC générée à partir du numéro de compagnie (unique par
   instance) puisque toutes les compagnies partagent le même réseau `default` — les autres cartes
   réseau réutilisent les MAC d'origine sans risque, car chaque compagnie a ses propres réseaux
   `LAN-X-CSNx`/`DMZ-X-CSNx` isolés.

Démarrage ensuite (ordre conseillé : serveur et firewall avant le client, pour que le réseau soit
prêt quand l'étudiant configure le client) :
```bash
virsh start CSNx-Server-B
virsh start CSNx-SNS-Firewall-B
virsh start CSNx-Client-B
```

## 4. Premier démarrage — étapes manuelles (par VM)

Ces étapes ne sont **pas** automatisables sans savoir précisément ce que le scénario pédagogique
attend ; à faire par le formateur/étudiant à chaque nouvelle session :

- **Serveur** : boot sur un écran texte « Please select your company from the list below... »
  (Company A à N+). Choisir la lettre correspondant à l'instance créée. Identifiants une fois
  démarré : `user`/`user` ou `root`/`root`.
- **Client** : boot sur un bureau XFCE avec un terminal Stormshield déjà ouvert (« WELCOME TO THE
  NETWORK CONFIGURATION TOOL ») proposant : une lettre de compagnie (trainee), `trainer`, `dhcp`,
  `manual`, ou `sns` (connexion à un firewall en config par défaut, 10.0.0.254). Faire le choix
  adapté à la session. Identifiants de session Alpine (au-delà de cet outil) : `user`/`user`.
- **Firewall** : boot jusqu'au prompt `login:` (NS-BSD). Identifiants : `admin`/`admin`. L'interface
  `out` (WAN) est **désactivée par défaut** — c'est le comportement observé de base Stormshield, pas
  un bug de la conversion ; l'activer/la configurer selon ce qu'attend le scénario de formation
  (CSNA, CSNE, CSNR, CSNTS...) — webadmin HTTPS sur l'IP de management, ou CLI ; se référer à la
  documentation Stormshield officielle, non couverte ici.

Pour vérifier l'état de boot sans ouvrir virt-manager :
```bash
virsh screenshot <nom-vm> /tmp/check.png
```
Le firewall n'a **pas** de sortie sur la console série (`virsh console` ne montre rien dessus) —
utiliser uniquement `virsh screenshot` ou la console graphique (VNC/spice) pour lui.

## 5. Fin de session / nettoyage

Le script gère lui-même la suppression (VM arrêtées si besoin, définitions retirées, disques
supprimés) :
```bash
./new-company-lab.sh B --remove        # VM + disques de la compagnie B, réseaux conservés
./new-company-lab.sh B --remove-all    # VM + disques + réseaux LAN-B-CSNx/DMZ-B-CSNx
```
Les deux modes demandent une confirmation (`o`/`N`) avant d'agir ; ajoute `-y` (ou `--yes`) pour
l'éviter (utile en script). Les images maîtres ne sont jamais concernées. Garder les réseaux
(`--remove`) a du sens si tu comptes recréer la même compagnie prochainement ; `--remove-all` fait
place nette complètement.

Équivalent manuel si besoin (ce que fait `--remove-all` en interne) :
```bash
virsh destroy CSNx-Server-B CSNx-Client-B CSNx-SNS-Firewall-B   # arrêt immédiat
virsh undefine CSNx-Server-B CSNx-Client-B CSNx-SNS-Firewall-B  # retire la définition
sudo rm /var/lib/libvirt/images/CSNx-{Server,Client,SNS-Firewall}-B.qcow2
virsh net-destroy LAN-B-CSNx DMZ-B-CSNx
virsh net-undefine LAN-B-CSNx DMZ-B-CSNx
```

## 6. Référence technique complète

| | Server | Client | Firewall |
|---|---|---|---|
| OS invité | Debian 5.0.10 Lenny i386 | Alpine 3.20 x86_64 | Stormshield SNS 4.8.14 (FreeBSD) |
| Bus disque | SCSI (`model='lsilogic'`) | SCSI (`model='lsilogic'`) | **virtio** (`bus='virtio'`) — SCSI ne boote pas, voir §7 |
| Carte(s) réseau | 1× e1000 | 1× e1000 | 3× e1000, **ordre = zone** (1=WAN, 2=LAN, 3=DMZ) |
| RAM / vCPU | 96 Mo / 2 | 3072 Mo / 2 | 1000 Mo / **1** |
| Machine / firmware | pc-i440fx, BIOS (pas d'UEFI) | pc-i440fx, BIOS | pc-i440fx, BIOS |
| Identifiants | user/user, root/root | user/user | admin/admin |
| Réseau (compagnie X) | `DMZ-X-CSNx` (172.16.y.0/24) | `LAN-X-CSNx` (192.168.y.0/24) | WAN=`default`, LAN=`LAN-X-CSNx`, DMZ=`DMZ-X-CSNx` |

**Firewall limité à 1 vCPU / 2 Go RAM max** : la licence pédagogique Stormshield fournie est une
**EVA1**, qui ne supporte qu'1 CPU (et 2 Go de RAM au maximum). Ne pas augmenter au-delà, même si
l'OVF d'origine déclarait 2 vCPU — ce chiffre venait de VirtualBox, pas de la licence réellement
utilisée.

## 7. Problèmes rencontrés (et solutions)

- **Le firewall ne boote pas en SCSI/lsilogic** (le contrôleur d'origine VirtualBox) : le loader
  FreeBSD reste bloqué sur `Root mount waiting for: usbus0` puis `Mounting from ufs:/dev/ufs/main
  failed with error 19` — aucun disque détecté du tout. Le noyau Stormshield n'a apparemment pas le
  driver pour ce vieux chip LSI 53c895a (produit conçu pour tourner sur KVM via virtio, pas pour
  imiter le matériel par défaut de VirtualBox). **Solution : bus='virtio'** sur le disque du
  firewall — boote du premier coup. Server et Client, eux, restent en SCSI/lsilogic sans problème.
- **VM qui semble « ne pas démarrer »** alors qu'elle tourne déjà (`virsh domstate` = running) :
  vérifier via `virsh screenshot` avant de conclure à un problème — un onglet virt-manager resté sur
  un ancien état, ou un test fait avant une correction, peut donner une fausse impression de blocage.
- **Ordre des cartes réseau du firewall** : déterminant pour que Stormshield assigne les bonnes
  zones (out/in/dmz1). Reproduit en gardant l'ordre exact des `<interface>` dans le XML libvirt
  (slot OVF 0/1/2 → 1ère/2e/3e interface déclarée) — vérifié correct via l'écran d'état au boot.
- **MAC déclarée dans l'OVF ≠ MAC réellement attendue par l'invité** (rencontré sur le serveur : la
  règle udev `/etc/udev/rules.d/70-persistent-net.rules` de l'invité pointait vers une MAC
  différente de celle de l'OVF — VirtualBox régénère les MAC par défaut à l'export). Toujours
  vérifier cette règle avant de faire confiance à la MAC de l'OVF pour un disque Debian/Linux ancien.
- **Anciens exports VMware/VirtualBox en IDE plutôt qu'en SCSI/virtio d'origine** : le noyau peut
  nommer le disque `/dev/hdaX` au lieu du `/dev/sdaX` attendu par fstab/GRUB (rencontré sur un export
  Debian antérieur à ce lab, hors OVA). Diagnostic : `virsh screenshot` montre le blocage sur
  « Waiting for root file system ». Correction : éditer `/etc/fstab` et l'entrée GRUB par défaut pour
  faire correspondre le nom de device réellement détecté (via `guestfish download`/`upload`).
- **Bug corrigé dans `new-company-lab.sh` (2026-09-09), `--remove`/`--remove-all` laissaient parfois
  un réseau actif mais « non persistant »** (visible via `virsh net-info` : `Active: yes` mais
  `Persistent: no`) au lieu de le supprimer complètement. Cause : le script pré-vérifiait l'état actif
  via `virsh net-info … | grep -q "Active.*yes"` avant d'appeler `net-destroy` — `grep -q` sort dès
  qu'il trouve son match, ce qui peut couper le pipe avant que `virsh` ait fini d'écrire (SIGPIPE) ;
  avec `pipefail` (actif via `set -euo pipefail`), le statut de la pipeline reflète alors ce SIGPIPE
  plutôt que le vrai résultat du grep, et la condition `if` est vue comme fausse — `net-destroy` est
  sauté à tort, seul `net-undefine` s'exécute, d'où ce réseau « actif mais non défini ». Comportement
  non déterministe (dépend du timing exact du pipe), donc pas toujours reproductible. **Correction** :
  ne plus pré-vérifier l'état du tout — appeler directement `net-destroy`/`destroy` et ignorer
  l'erreur avec `|| true` si la ressource était déjà arrêtée. Même piège à éviter pour toute VM/réseau
  libvirt : ne pas conditionner une action sur un `virsh ... | grep -q ...` sous `pipefail`.

## 8. Le réseau `default` (NAT) existant

Aucune action nécessaire : le réseau `default` de cet hôte est déjà un réseau NAT actif
(`forward mode='nat'`, DHCP dynamique), c'est exactement ce qu'attend le WAN de chaque firewall.
Toutes les compagnies y branchent leur carte WAN — seule leur MAC diffère (générée par le script),
donc pas de conflit. Ce réseau est aussi utilisé par d'autres VM de la stack (ex: `windows-11`) ;
rien de spécifique au lab CSNx n'y a été modifié.
