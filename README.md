# macbuntu

Ubuntu sur **MacBook Pro 15" 2017 avec Touch Bar (MacBookPro14,3)**, avec tout le matériel fonctionnel :
Wi-Fi, Touch Bar, webcam, haut-parleurs, casque Bluetooth, clavier ISO.

Testé le 9 octobre 2026 sur Ubuntu 26.04.1 LTS, noyau `7.0.0-38-generic`
(i7-7920HQ, 16 Go, SSD 512 Go, Intel HD 630 + Radeon Pro 555).

```bash
sudo apt install git      # seul prérequis : le script installe lui-même tout le reste
git clone --recurse-submodules https://github.com/ruggdoll/macbuntu
cd macbuntu
./install.sh              # tout, dans l'ordre (relançable à volonté)
./install.sh --list       # les sections
./install.sh wifi audio   # seulement certaines sections
```

`install.sh` est **idempotent** : chaque étape vérifie l'état de la machine et ne fait rien si c'est
déjà en place. Il se lance en utilisateur normal, depuis la session graphique, et demande `sudo`
quand il en a besoin. À la fin, il indique s'il faut un arrêt complet.

| Matériel | État d'origine | Correctif | Section |
| --- | --- | --- | --- |
| Clavier, trackpad (SPI) | OK sauf `@#` / `<>` inversés | option `applespi iso_layout=1` | `clavier` |
| GPU Intel + AMD | OK | — | — |
| Wi-Fi BCM43602 | association refusée, pas de 5 GHz | fichier de calibration NVRAM | `wifi` |
| Touch Bar, webcam, capteur de lumière (puce T1) | T1 en mode recovery, Touch Bar noire | firmware T1 régénéré + t1bridge | `t1`, `touchbar` |
| Boutons volume et multimédia de la Touch Bar | absents / inactifs | fournisseur de bureau maison | `touchbar-boutons` |
| Webcam dans les applis | « aucune caméra » (H.264 seulement) | caméra virtuelle v4l2-relayd | `webcam` |
| Haut-parleurs (Cirrus CS8409 + MAX98706) | muets | pilote davidjo en DKMS | `audio` |
| Casque Bluetooth | son haché | commande Broadcom « Set ACL Priority » | `bluetooth` |
| Veille | casse la T1 | veille désactivée, écran fermé = verrouillage | `energie` |
| Carillon au démarrage | joue à chaque allumage | NVRAM Apple `StartupMute=01` | `carillon` |
| Touch ID | non installé | possible avec t1bridge, non fait | — |

## Contenu du dépôt

- `install.sh` : le script.
- `files/` : configurations et petits scripts installés par le script.
- `vendor/` : les projets tiers, en sous-modules git **fixés sur les versions testées** :
  - [`niconistal/t1-revive`](https://github.com/niconistal/t1-revive) `v0.1.5` (régénération du firmware T1, fichier NVRAM Wi-Fi)
  - [`standardagents/t1bridge`](https://github.com/standardagents/t1bridge) `v0.1.12` (Touch Bar, webcam)
  - [`davidjo/snd_hda_macbookpro`](https://github.com/davidjo/snd_hda_macbookpro) `89b22ff` (audio)

Le firmware de la T1 n'est **pas** dans ce dépôt : il est propre à chaque puce (`FDRData` est la
clé de Touch ID de la machine), c'est du code Apple non redistribuable, et le script le régénère.

---

## Détail des correctifs

### `clavier` : touches `@ #` et `< >` inversées

Le pilote SPI du clavier (`applespi`) suppose une disposition ANSI. Sur un clavier ISO (français),
la touche en haut à gauche et celle à côté de Maj gauche sont échangées.
→ `/etc/modprobe.d/applespi-iso.conf` : `options applespi iso_layout=1`.

Disposition GNOME « Français (Macintosh) » : les caractères spéciaux passent **uniquement par
l'Option de droite** (`level3(ralt_switch)`), l'Option de gauche est un Alt normal.

| Caractère | Combinaison |
| --- | --- |
| `\|` | Option droite + Maj + L |
| `\` | Option droite + Maj + `:` |
| `¬` | Option droite + L |
| `≤` / `≥` | Option droite + `<` (sans / avec Maj) |

Trackpad : clic droit = clic ou tape à deux doigts, clic du milieu = trois doigts.

### `wifi` : BCM43602

`linux-firmware` ne fournit pas `brcmfmac43602-pcie.txt`. Sans lui : adresse MAC générique
`00:90:4c:…`, peu de réseaux, pas de 5 GHz, `CTRL-EVENT-ASSOC-REJECT status_code=16` même avec le
bon mot de passe. Le fichier vient de `vendor/t1-revive/contrib/stick/`, avec la MAC de la carte et
le pays `FR` → `/lib/firmware/brcm/brcmfmac43602-pcie.txt`.

### `t1` : la puce T1 en mode recovery

La Touch Bar, la webcam, le capteur de lumière et Touch ID passent par la puce T1. Son système est
chargé au démarrage depuis `EFI/APPLE/EMBEDDEDOS/` sur la partition EFI, que **l'installeur
Ubuntu efface**. La T1 apparaît alors en `05ac:1281 Apple Mobile Device [Recovery Mode]` au lieu de
`05ac:8600 iBridge`, et aucun pilote ne peut rien y faire.

t1-revive rejoue la restauration d'Apple depuis Linux : il télécharge le firmware T1 officiel chez
Apple, la puce récupère ses données d'usine signées, puis l'outil écrit `combined.memboot`,
`FDRData` et `version.plist` dans `EMBEDDEDOS/`. Comptez environ 5 minutes, sur secteur et sans
veille. Le script compile les outils, fait un essai à blanc, puis demande confirmation.
L'outil est prévu pour Arch : l'avertissement « Arch-based systems only » du preflight est sans
importance, le script installe les équivalents Ubuntu.

**Après la régénération, copier `/boot/efi/EFI/APPLE` sur un support externe**, et le remettre en
place après toute réinstallation.

### `touchbar` : t1bridge compilé pour Ubuntu

t1bridge n'a de paquets que pour Arch. Le script compile les deux programmes de la Touch Bar
(Rust), installe les 4 modules noyau en DKMS (`t1_cfgsel`, `appletbdrm`, `apple_t1_ncm`,
`uvcvideo` patché), les services systemd, la règle udev, et ajoute l'utilisateur au groupe
`t1bridge`, faute de quoi la Touch Bar reste noire. `t1_cfgsel` doit être chargé avant que la T1
apparaisse : il est ajouté à l'initramfs (`/etc/dracut.conf.d/t1bridge.conf` sur Ubuntu 26.04, qui
utilise dracut ; `/etc/initramfs-tools/modules` sur les versions plus anciennes).
Touch ID (libfprint/fprintd modifiés, PAM) n'est pas installé.

Deux pièges propres à Ubuntu :
- **usbmuxd** (le service des iPhone) prend la T1 pour un iPhone et force
  `bConfigurationValue=0` à chaque démarrage : Touch Bar éteinte, pas de webcam. Le script installe
  `/etc/udev/rules.d/39-usbmuxd.rules`, une copie de la règle sans `5ac/8600`. Les iPhone restent
  gérés. Dépannage à chaud : `echo 2 | sudo tee /sys/bus/usb/devices/1-3/bConfigurationValue`.
- Le lien réseau privé de la T1 (`apple_t1_ncm`) est ignoré par NetworkManager, sinon il tente du
  DHCP dessus.

Boutons de luminosité : t1bridge coupe ce contrôle au premier échec, jusqu'au redémarrage de son
service. S'ils ne répondent pas : `sudo systemctl restart t1-touchbar-hw.service`. La luminosité
automatique de GNOME, qui exploite le capteur de la T1, est désactivée (section `energie`) : elle
se battait avec les réglages manuels.

### `touchbar-boutons` : volume et multimédia

Sans « fournisseur de bureau », t1bridge cache les boutons de volume et affiche ⏮ ⏯ ⏭ sans effet.
`files/touchbar/t1bridge-desktop` implémente le contrat « Desktop provider v1 »
(`vendor/t1bridge/docs/interfaces.md`) : volume et coupure via `wpctl`, lecture via `playerctl`.
⏮ ⏭ changent de piste si le lecteur en a une (playlist, Spotify), sinon reculent ou avancent de
10 s (vidéo YouTube seule). Il est activé par une surcharge du service utilisateur
`t1-touchbar.service` (`T1BRIDGE_DESKTOP_PROVIDER`).

### `webcam` : caméra virtuelle

La caméra de la T1 ne sort que du **H.264**, que les applis (Caméra, navigateurs, visio) ne lisent
pas. `v4l2-relayd` la décode vers une caméra virtuelle v4l2loopback « FaceTime HD » en YUY2, et
n'allume la vraie caméra (et sa LED) que lorsqu'une appli l'ouvre. Deux correctifs :
- `sync=false` sur `v4l2sink` (surcharge `v4l2-relayd@facetime.service.d/sync.conf`), sans quoi
  presque toutes les images sont jetées : environ 1 image/s au lieu de 28 ;
- une règle WirePlumber masque la caméra H.264 brute, pour que les applis prennent « FaceTime HD ».

### `audio` : haut-parleurs

Le `snd-hda-codec-cs8409` du noyau ne connaît que des cartes Dell. Sur ce Mac (`106b:3900`), il
n'allume pas les amplis MAX98706 : le signal sort mais les haut-parleurs restent muets. Le projet
davidjo ajoute la prise en charge du « MacBookPro 14,3 ». Plutôt que son script d'installation,
le dépôt fournit une recette DKMS courte (`files/audio/prebuild.sh` + `dkms.conf`) : extraire
`sound/hda` du paquet `linux-source-<version>`, appliquer les correctifs, compiler
`snd-hda-codec-cs8409`. DKMS recompile à chaque nouveau noyau, à condition que le paquet
`linux-source-<version>` correspondant soit installé.
Dans `journalctl -k`, `patch_cs8409 NOT FOUND trying APPLE` signale que le code Apple a pris la main.
Pour annuler : `sudo dkms remove snd-hda-macbookpro/89b22ff --all`.

### `bluetooth` : casque haché

Souris et clavier Bluetooth marchent tels quels. Mais l'audio vers un casque (A2DP) coupait toutes
les quelques secondes, quel que soit le codec et même Wi-Fi coupé. La puce Broadcom BCM20703A2 a
besoin de la commande vendeur **« Set ACL Priority »** (OGF `0x3f`, OCF `0x57`) pour prioriser le
flux audio. macOS et Android l'envoient, pas Linux ([bluez#1976](https://github.com/bluez/bluez/issues/1976)).
`bt-acl-priority.service` l'envoie à chaque nouvelle liaison classique (les périphériques LE comme
une souris ne sont pas concernés).
Test manuel : `sudo hcitool cmd 0x3f 0x57 0x0C 0x00 0x01` (handle de `hcitool con`) → `01 57 FC 00` = succès.

Sans rapport et sans conséquence : `failed to write update baudrate (-16)` et
`Patch file not found 'brcm/BCM.hcd'` au démarrage. L'ACPI déclare 3 Mbit/s, comme le pilote
Windows Boot Camp, qui ne fournit pas non plus de firmware pour cette puce.

### `energie` : pas de veille

La T1 ne survit pas à la mise en veille. La veille automatique est coupée (secteur et batterie), et
fermer l'écran verrouille la session (`/etc/systemd/logind.conf.d/10-pas-de-veille-t1.conf`).
Éteindre le Mac pour le transporter.

### `carillon` : pas de son au démarrage

Le « boing » est joué par le firmware du Mac : son contenu n'est pas modifiable, mais on peut le
couper avec la variable NVRAM Apple `StartupMute` = `01` (équivalent de `sudo nvram StartupMute=%01`
sous macOS), écrite via `/sys/firmware/efi/efivars/StartupMute-7c436110-ab2a-4bbb-a880-fe41995c9f82`.
Pour le réactiver : `sudo chattr -i` puis `sudo rm` sur ce fichier.
La pomme grise affichée à l'allumage vient elle aussi du firmware et n'est pas modifiable.

---

## Vérifications

```bash
lsusb | grep 05ac                                   # 05ac:8600 iBridge (pas 1281)
cat /sys/bus/usb/devices/1-3/bConfigurationValue    # 2
systemctl is-active t1-touchbar-hw v4l2-relayd@facetime bt-acl-priority
systemctl --user is-active t1-touchbar
dkms status                                         # t1bridge-dkms, snd-hda-macbookpro : installed
wpctl status                                        # Vidéo : FaceTime HD ; Audio : Audio interne
```

## Optionnel : sudo sans mot de passe

```bash
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/90-$USER-nopasswd >/dev/null
sudo chmod 440 /etc/sudoers.d/90-$USER-nopasswd && sudo visudo -c
```

## Licences

Le contenu propre à ce dépôt (`install.sh`, `files/`, documentation) est sous licence MIT.
Les sous-modules gardent leurs licences : t1-revive (MIT, avec des correctifs LGPL/GPL),
t1bridge (MIT, modules noyau GPL-2.0) et snd_hda_macbookpro (GPL-2.0). Le fichier NVRAM Wi-Fi
provient de t1-revive.
