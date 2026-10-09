#!/bin/sh
# Prepare le code audio du noyau $1 avec les correctifs Apple (davidjo/snd_hda_macbookpro)
# Memes etapes que la compilation manuelle : extraire sound/hda, Makefiles, fichiers Apple, correctifs.
set -e
kver="$1"; base="${kver%%-*}"                  # 7.0.0-38-generic -> 7.0.0
src="/usr/src/linux-source-$base.tar.bz2"
[ -e "$src" ] || { echo "Sources manquantes : sudo apt install linux-source-$base" >&2; exit 1; }
cd "$(dirname "$0")"
rm -rf build && mkdir build
tar --strip-components=2 -xjf "$src" -C build "linux-source-$base/sound/hda"
H=build/hda
for m in "" common/ codecs/ codecs/cirrus/; do mv "$H/${m}Makefile" "$H/${m}Makefile.orig"; done
cp makefiles/Makefile "$H/Makefile"
cp makefiles/Makefile_common "$H/common/Makefile"
cp makefiles/Makefile_codecs "$H/codecs/Makefile"
cp makefiles/Makefile_cirrus "$H/codecs/cirrus/Makefile"
cp patch_cirrus/cirrus_apple.h patch_cirrus/patch_cirrus_boot84.h patch_cirrus/patch_cirrus_new84.h \
   patch_cirrus/patch_cirrus_real84.h patch_cirrus/patch_cirrus_hda_generic_copy.h \
   patch_cirrus/patch_cirrus_real84_i2c.h "$H/codecs/cirrus/"
cd "$H" && patch -p1 < ../../patch_cs8409.c.diff && patch -p1 < ../../patch_cs8409.h.diff
