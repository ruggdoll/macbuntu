#!/usr/bin/env bash
# macbuntu : Ubuntu sur MacBook Pro 15" 2017 (MacBookPro14,3), script idempotent.
#
#   ./install.sh                 toutes les sections, dans l'ordre
#   ./install.sh wifi audio      seulement ces sections
#   ./install.sh --list          liste des sections
#
# À lancer en utilisateur normal (pas sudo), dans la session graphique : le script
# demande sudo quand il en a besoin. Relançable à volonté : chaque étape vérifie
# d'abord l'état de la machine et ne fait rien si c'est déjà en place.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FILES=$REPO/files
WORK=/opt/macbuntu                       # copies de travail des dépôts tiers (compilations)
KVER=$(uname -r)
KBASE=${KVER%%-*}                        # 7.0.0-38-generic -> 7.0.0
NEED_INITRAMFS=0
NEED_REBOOT=0
CHANGED=0

SECTIONS=(paquets clavier wifi t1 touchbar touchbar-boutons webcam audio bluetooth energie)

# ---------------------------------------------------------------- outils ----
titre() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fait()  { printf '  \033[33m+\033[0m %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
stop()  { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# put SRC DEST [MODE] : copie (root) seulement si le contenu diffère ; CHANGED=1 si copie.
put() {
  local src=$1 dst=$2 mode=${3:-644}
  if sudo test -f "$dst" && sudo cmp -s "$src" "$dst"; then return 0; fi
  sudo install -D -m "$mode" "$src" "$dst"; fait "$dst"; CHANGED=1
}
# putc DEST [MODE] : comme put, contenu lu sur l'entrée standard.
putc() {
  local tmp; tmp=$(mktemp); cat >"$tmp"; put "$tmp" "$1" "${2:-644}"; rm -f "$tmp"
}
# uput SRC DEST [MODE] : comme put, côté utilisateur (sans sudo).
uput() {
  local src=$1 dst=$2 mode=${3:-644}
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then return 0; fi
  install -D -m "$mode" "$src" "$dst"; fait "$dst"; CHANGED=1
}
# apt_install PAQUET... : installe seulement ceux qui manquent.
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p"); done
  if ((${#missing[@]})); then
    fait "paquets : ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
}
# dkms_installed NOM VERSION
dkms_installed() { dkms status -m "$1" -v "$2" -k "$KVER" 2>/dev/null | grep -q ': installed'; }
# workcopy NOM : copie de travail de vendor/NOM dans $WORK/NOM, au commit fixé par le sous-module.
workcopy() {
  local name=$1 want dst=$WORK/$1
  want=$(git -C "$REPO" ls-tree HEAD "vendor/$name" 2>/dev/null | awk '{print $3}') || true
  [[ -n $want ]] || want=$(git -C "$REPO/vendor/$name" rev-parse HEAD)
  if [[ ! -d $dst/.git ]]; then
    sudo install -d -o "$USER" -g "$USER" "$WORK"
    git clone -q "$REPO/vendor/$name" "$dst"; fait "$dst"
  fi
  if [[ $(git -C "$dst" rev-parse HEAD) != "$want" ]]; then
    git -C "$dst" fetch -q "$REPO/vendor/$name" "$want" 2>/dev/null || git -C "$dst" fetch -q origin
    git -C "$dst" checkout -q "$want"; fait "$name @ ${want:0:7}"
  fi
}
has_session() { [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] && command -v gsettings >/dev/null; }
gset() { # gset SCHEMA CLE VALEUR
  [[ $(gsettings get "$1" "$2") == "$3" ]] && return 0
  gsettings set "$1" "$2" "$3"; fait "gsettings $2 = $3"
}

# --------------------------------------------------------------- sections ---
s_paquets() {
  titre "Paquets de base"
  apt_install git build-essential dkms "linux-headers-$KVER" pkg-config curl
  ok "outils de compilation et en-têtes du noyau $KVER"
  if [[ ! -e $REPO/vendor/t1bridge/Cargo.toml ]]; then
    git -C "$REPO" submodule update --init --recursive; fait "sous-modules récupérés"
  fi
  ok "sous-modules : $(git -C "$REPO" submodule status | awk '{printf "%s@%s ", $2, substr($1,1,7)}' | tr -d '+-')"
}

s_clavier() {
  titre "Clavier ISO (touches @# et <> inversées)"
  CHANGED=0
  put "$FILES/modprobe/applespi-iso.conf" /etc/modprobe.d/applespi-iso.conf
  ((CHANGED)) && NEED_INITRAMFS=1
  if [[ $(cat /sys/module/applespi/parameters/iso_layout 2>/dev/null) != Y ]]; then
    echo Y | sudo tee /sys/module/applespi/parameters/iso_layout >/dev/null; fait "iso_layout activé à chaud"
  fi
  ok "applespi iso_layout=1"
}

s_wifi() {
  titre "Wi-Fi BCM43602 (fichier de calibration NVRAM)"
  local ifc mac
  ifc=$(basename "$(ls -d /sys/class/net/wl* 2>/dev/null | head -1)" 2>/dev/null || true)
  [[ -n $ifc && -e /sys/class/net/$ifc ]] || { info "pas d'interface Wi-Fi, section ignorée"; return; }
  mac=$(cat "/sys/class/net/$ifc/address")
  CHANGED=0
  sed -e "s/^macaddr=.*/macaddr=$mac/" -e "s/^ccode=.*/ccode=FR/" \
      "$REPO/vendor/t1-revive/contrib/stick/brcmfmac43602-pcie.txt" \
    | putc /lib/firmware/brcm/brcmfmac43602-pcie.txt
  if ((CHANGED)); then
    sudo modprobe -r brcmfmac_wcc brcmfmac 2>/dev/null || true; sudo modprobe brcmfmac
    fait "pilote brcmfmac rechargé"
  fi
  ok "NVRAM brcmfmac43602-pcie.txt (pays FR, MAC $mac)"
}

s_t1() {
  titre "Puce T1 (firmware dans EFI/APPLE/EMBEDDEDOS)"
  if lsusb -d 05ac:8600 >/dev/null 2>&1; then ok "T1 démarrée (05ac:8600 iBridge)"; return; fi
  lsusb -d 05ac:1281 >/dev/null 2>&1 || { info "T1 introuvable sur l'USB : faire un arrêt complet puis relancer."; return; }
  info "T1 en mode recovery (05ac:1281) : régénération du firmware avec t1-revive (Apple, ~5 min)."
  grep -q 1 /sys/class/power_supply/ADP1/online 2>/dev/null || stop "Brancher le chargeur avant la régénération."
  apt_install autoconf automake libtool libzip-dev libusb-1.0-0-dev libcurl4-openssl-dev \
              libssl-dev libreadline-dev acpi-call-dkms
  workcopy t1-revive
  if [[ ! -x $WORK/t1-revive/prefix/bin/idevicerestore ]]; then
    info "compilation des outils libimobiledevice patchés (quelques minutes)…"
    (cd "$WORK/t1-revive" && bash build.sh >build.log 2>&1) || stop "échec de build.sh (voir $WORK/t1-revive/build.log)"
    fait "outils t1-revive compilés"
  fi
  sudo modprobe acpi_call
  sudo "$WORK/t1-revive/bin/t1-revive" regenerate --dry-run --no-confirm >/dev/null || stop "l'essai à blanc de t1-revive a échoué"
  ok "essai à blanc réussi"
  read -rp "    Lancer la régénération maintenant ? (secteur, pas de veille) [o/N] " r
  [[ $r =~ ^[oOyY]$ ]] || { info "régénération reportée"; return; }
  sudo "$WORK/t1-revive/bin/t1-revive" regenerate || stop "t1-revive s'est arrêté : voir la commande --from qu'il indique."
  fait "firmware T1 régénéré"
  info "IMPORTANT : copier /boot/efi/EFI/APPLE sur un support externe (clé de Touch ID)."
  NEED_REBOOT=1
}

s_touchbar() {
  titre "Touch Bar et webcam : t1bridge"
  apt_install rustc cargo libarchive-dev liblzma-dev libsystemd-dev iio-sensor-proxy
  workcopy t1bridge
  local S=$WORK/t1bridge P=$WORK/t1bridge/packaging/arch/t1bridge-dkms
  (cd "$S" && cargo build -q --locked --release -p t1-touchbar-hw --bin t1-touchbar-hw --features service \
           && cargo build -q --locked --release -p t1-touchbar --bin t1-touchbar)
  CHANGED=0
  put "$S/target/release/t1-touchbar-hw" /usr/lib/t1bridge/t1-touchbar-hw 755
  put "$S/target/release/t1-touchbar"    /usr/lib/t1bridge/t1-touchbar 755
  local bin_changed=$CHANGED

  # Modules noyau (DKMS)
  local V D f
  V=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$S/kernel/dkms/dkms.conf"); D=/usr/src/t1bridge-dkms-$V
  CHANGED=0
  for f in t1-cfgsel/{Makefile,t1_cfgsel.c,t1_recovery_reset.h} \
           appletbdrm-t1/{Makefile,appletbdrm.c,appletbdrm_resume.h,appletbdrm_protocol.h} \
           apple-t1-ncm/{Makefile,apple_t1_ncm.c} dkms/Makefile; do
    put "$S/kernel/$f" "$D/kernel/$f"
  done
  for f in "$S"/kernel/uvcvideo-t1/{Makefile,uvc_*.c,uvc_*.h,uvcvideo.h}; do
    put "$f" "$D/kernel/uvcvideo-t1/$(basename "$f")"
  done
  put "$S/kernel/dkms/dkms.conf" "$D/dkms.conf"
  if ((CHANGED)) && dkms status -m t1bridge-dkms -v "$V" 2>/dev/null | grep -q .; then
    sudo dkms remove -q "t1bridge-dkms/$V" --all >/dev/null 2>&1 || true
  fi
  if ! dkms_installed t1bridge-dkms "$V"; then
    sudo dkms install -q "t1bridge-dkms/$V" >/dev/null; fait "DKMS t1bridge-dkms/$V"; NEED_REBOOT=1
  fi
  ok "modules t1_cfgsel, appletbdrm, apple_t1_ncm, uvcvideo (DKMS $V)"

  # Services, udev, configuration
  CHANGED=0
  put "$S/systemd/t1-touchbar-hw.service"       /usr/lib/systemd/system/t1-touchbar-hw.service
  put "$S/systemd/t1-touchbar-hw.socket"        /usr/lib/systemd/system/t1-touchbar-hw.socket
  put "$S/systemd/user/t1-touchbar.service"     /usr/lib/systemd/user/t1-touchbar.service
  put "$S/systemd/t1bridge.sysusers"            /usr/lib/sysusers.d/t1bridge.conf
  put "$S/systemd/t1bridge.conf"                /usr/lib/tmpfiles.d/t1bridge.conf
  put "$S/systemd/99-zz-t1bridge-touchbar.rules" /usr/lib/udev/rules.d/99-zz-t1bridge-touchbar.rules
  put "$S/systemd/50-t1bridge-ncm.link"         /usr/lib/systemd/network/50-t1bridge-ncm.link
  put "$P/t1bridge.modules-load.conf"           /usr/lib/modules-load.d/t1bridge.conf
  put "$P/t1bridge.modprobe.conf"               /usr/lib/modprobe.d/t1bridge.conf
  # usbmuxd (iPhone) prend la T1 pour un iPhone et la déconfigure à chaque démarrage : on l'exclut.
  { echo "# Copie de /usr/lib/udev/rules.d/39-usbmuxd.rules sans 5ac/8600 :"
    echo "# la T1 (iBridge) n'est pas un iPhone ; usbmuxd la deconfigurait et cassait Touch Bar/webcam."
    sed 's#|5ac/8600/\*##' /usr/lib/udev/rules.d/39-usbmuxd.rules; } | putc /etc/udev/rules.d/39-usbmuxd.rules
  local units_changed=$CHANGED
  if ! grep -qx t1_cfgsel /etc/initramfs-tools/modules; then
    echo t1_cfgsel | sudo tee -a /etc/initramfs-tools/modules >/dev/null; fait "t1_cfgsel dans l'initramfs"; units_changed=1
  fi
  if ((units_changed)); then
    NEED_INITRAMFS=1
    sudo systemd-sysusers; sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/t1bridge.conf
    sudo systemctl daemon-reload; sudo udevadm control --reload
  fi
  id -nG "$USER" | grep -qw t1bridge || { sudo usermod -aG t1bridge "$USER"; fait "$USER ajouté au groupe t1bridge (nouvelle session nécessaire)"; NEED_REBOOT=1; }
  systemctl is-enabled -q t1-touchbar-hw.service 2>/dev/null || { sudo systemctl enable -q t1-touchbar-hw.service t1-touchbar-hw.socket; fait "t1-touchbar-hw activé"; }
  [[ -L /etc/systemd/user/default.target.wants/t1-touchbar.service ]] || { sudo systemctl --global enable -q t1-touchbar.service; fait "t1-touchbar (session) activé"; }
  if ((bin_changed)) && systemctl is-active -q t1-touchbar-hw.service; then
    sudo systemctl restart t1-touchbar-hw.service; fait "t1-touchbar-hw redémarré"
  fi
  CHANGED=0
  put "$FILES/networkmanager/90-t1bridge-unmanaged.conf" /etc/NetworkManager/conf.d/90-t1bridge-unmanaged.conf
  ((CHANGED)) && sudo nmcli general reload conf
  ok "services, règles udev (dont usbmuxd), groupe t1bridge, lien réseau T1 ignoré par NetworkManager"
}

s_touchbar_boutons() {
  titre "Touch Bar : boutons volume et multimédia (fournisseur de bureau)"
  apt_install playerctl
  CHANGED=0
  uput "$FILES/touchbar/t1bridge-desktop" "$HOME/.local/bin/t1bridge-desktop" 755
  local tmp; tmp=$(mktemp); sed "s#@HOME@#$HOME#" "$FILES/touchbar/provider.conf.in" >"$tmp"
  uput "$tmp" "$HOME/.config/systemd/user/t1-touchbar.service.d/provider.conf"; rm -f "$tmp"
  if ((CHANGED)) && has_session; then
    systemctl --user daemon-reload; systemctl --user restart t1-touchbar.service 2>/dev/null || true
    fait "t1-touchbar redémarré"
  fi
  ok "t1bridge-desktop (volume via wpctl, ⏮⏯⏭ via playerctl)"
}

s_webcam() {
  titre "Webcam : caméra virtuelle « FaceTime HD » (H.264 décodé à la demande)"
  apt_install gstreamer1.0-plugins-bad gstreamer1.0-libav v4l2-relayd v4l-utils
  CHANGED=0
  put "$FILES/v4l2-relayd/v4l2loopback.conf" /etc/modprobe.d/v4l2-relayd.conf
  local mod_changed=$CHANGED; CHANGED=0
  put "$FILES/v4l2-relayd/facetime.conf" /etc/v4l2-relayd.d/facetime.conf
  put "$FILES/v4l2-relayd/sync.conf"     /etc/systemd/system/v4l2-relayd@facetime.service.d/sync.conf
  local svc_changed=$CHANGED
  if ((mod_changed)); then
    sudo systemctl stop v4l2-relayd.service 2>/dev/null || true
    sudo modprobe -r v4l2loopback 2>/dev/null || NEED_REBOOT=1
    sudo modprobe v4l2loopback; fait "v4l2loopback rechargé"; svc_changed=1
  fi
  if ((svc_changed)); then
    sudo systemctl daemon-reload; sudo systemctl enable -q v4l2-relayd.service; sudo systemctl restart v4l2-relayd.service
    fait "v4l2-relayd redémarré"
  fi
  CHANGED=0
  uput "$FILES/wireplumber/51-masquer-ibridge-h264.conf" "$HOME/.config/wireplumber/wireplumber.conf.d/51-masquer-ibridge-h264.conf"
  ((CHANGED)) && has_session && { systemctl --user restart wireplumber; fait "wireplumber redémarré"; }
  ok "v4l2-relayd@facetime (sync=false), caméra brute iBridge masquée"
}

s_audio() {
  titre "Audio : haut-parleurs (CS8409 + amplis MAX98706, pilote davidjo en DKMS)"
  apt_install "linux-source-$KBASE"
  workcopy snd_hda_macbookpro
  local R=$WORK/snd_hda_macbookpro V D f
  V=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$FILES/audio/dkms.conf"); D=/usr/src/snd-hda-macbookpro-$V
  CHANGED=0
  for f in Makefile patch_cs8409.c.diff patch_cs8409.h.diff LICENSE; do put "$R/$f" "$D/$f"; done
  for f in "$R"/makefiles/* "$R"/patch_cirrus/*; do put "$f" "$D/${f#"$R"/}"; done
  put "$FILES/audio/prebuild.sh" "$D/prebuild.sh" 755
  put "$FILES/audio/dkms.conf"   "$D/dkms.conf"
  if ((CHANGED)) && dkms status -m snd-hda-macbookpro -v "$V" 2>/dev/null | grep -q .; then
    sudo dkms remove -q "snd-hda-macbookpro/$V" --all >/dev/null 2>&1 || true
  fi
  if ! dkms_installed snd-hda-macbookpro "$V"; then
    sudo dkms install -q "snd-hda-macbookpro/$V" >/dev/null; fait "DKMS snd-hda-macbookpro/$V"; NEED_REBOOT=1
  fi
  ok "snd-hda-codec-cs8409 patché (DKMS $V, sources linux-source-$KBASE)"
}

s_bluetooth() {
  titre "Bluetooth : priorité audio pour les casques (Broadcom Set ACL Priority)"
  CHANGED=0
  put "$FILES/bluetooth/bt-acl-priority"         /usr/local/sbin/bt-acl-priority 755
  put "$FILES/bluetooth/bt-acl-priority.service" /etc/systemd/system/bt-acl-priority.service
  if ((CHANGED)); then sudo systemctl daemon-reload; sudo systemctl enable -q bt-acl-priority.service; sudo systemctl restart bt-acl-priority.service; fait "bt-acl-priority (re)démarré"; fi
  systemctl is-enabled -q bt-acl-priority.service || { sudo systemctl enable -q --now bt-acl-priority.service; fait "bt-acl-priority activé"; }
  ok "bt-acl-priority actif"
}

s_energie() {
  titre "Énergie : pas de veille (non supportée par la T1), luminosité auto coupée"
  CHANGED=0
  put "$FILES/logind/10-pas-de-veille-t1.conf" /etc/systemd/logind.conf.d/10-pas-de-veille-t1.conf
  ((CHANGED)) && { sudo systemctl kill -s HUP systemd-logind; fait "logind rechargé"; }
  if has_session; then
    gset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "'nothing'"
    gset org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "'nothing'"
    gset org.gnome.settings-daemon.plugins.power ambient-enabled false
  else
    info "pas de session graphique : réglages GNOME ignorés (relancer depuis le bureau)"
  fi
  ok "fermer l'écran verrouille au lieu de mettre en veille"
}

# ------------------------------------------------------------- programme ---
[[ $EUID -ne 0 ]] || stop "Lancer sans sudo (le script le demande quand il faut)."
if [[ ${1:-} == --list ]]; then printf '%s\n' "${SECTIONS[@]}"; exit 0; fi
[[ $(cat /sys/class/dmi/id/product_name) == MacBookPro14,3 ]] || stop "Prévu pour un MacBookPro14,3 uniquement."
sudo -v

todo=("$@"); ((${#todo[@]})) || todo=("${SECTIONS[@]}")
for s in "${todo[@]}"; do
  [[ " ${SECTIONS[*]} " == *" $s "* ]] || stop "section inconnue : $s (voir --list)"
  "s_${s//-/_}"
done

if ((NEED_INITRAMFS)); then titre "initramfs"; sudo update-initramfs -u >/dev/null; fait "initramfs régénéré"; NEED_REBOOT=1; fi
titre "Terminé"
((NEED_REBOOT)) && info "Faire un ARRÊT COMPLET puis rallumer pour tout prendre en compte." || ok "rien d'autre à faire"
