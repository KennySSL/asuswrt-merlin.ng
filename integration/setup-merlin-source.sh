#!/usr/bin/env bash
# =============================================================================
# setup-merlin-source.sh -- holt die Merlin-Quelle in ein Linux-Volume
#
# Warum nicht einfach auf den Desktop klonen:
#   Der Baum enthaelt release/src-rt-*/kernel/linux-4.1/drivers/gpu/drm/nouveau/
#   nvkm/subdev/i2c/aux.c. Windows reserviert AUX als Geraetenamen -- unabhaengig
#   von der Endung. "aux.c" ist auf NTFS nicht anlegbar, git checkout bricht ab.
#   Ein Linux-Volume (ext4/overlay) hat diese Grenze nicht.
#
# Aufruf:
#   bash integration/setup-merlin-source.sh
# =============================================================================
set -euo pipefail

VOL=${VOL:-merlin-tuf}
BRANCH=${BRANCH:-DEV_fix_tuf}
REPO=https://github.com/gnuton/asuswrt-merlin.ng.git
DEST=/src/asuswrt-merlin.ng

say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }

command -v docker >/dev/null || { echo "docker fehlt"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker laeuft nicht (Docker Desktop starten)"; exit 1; }

say "Volume anlegen: $VOL"
docker volume create "$VOL" >/dev/null

if docker run --rm -v "$VOL":/src ubuntu:24.04 test -d "$DEST/.git"; then
  say "Quelle ist schon da, ueberspringe den Clone"
else
  say "Clone: $REPO @ $BRANCH  (kann mehrere Minuten dauern)"
  docker run --rm -v "$VOL":/src ubuntu:24.04 bash -c "
    apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null 2>&1
    git clone --depth 1 --single-branch --branch '$BRANCH' '$REPO' '$DEST'
    cd '$DEST' && git submodule update --init --recursive 2>/dev/null || true
    echo
    echo 'HEAD:' \$(git log -1 --format='%h %ad %s')
    echo 'Groesse:' \$(du -sh . | cut -f1)
    echo
    echo '--- SDK-Ordner ---'
    ls -d release/src-rt-* 2>/dev/null | sed 's|.*/|  |'
  "
fi

say "Wichtige Pfade im Volume:"
docker run --rm -v "$VOL":/src ubuntu:24.04 bash -c "
  cd '$DEST'
  echo  '  Router-Makefile : ' release/src/router/Makefile
  echo  '  TUF-Prebuilds   :'
  ls -d release/src/router/bwdpi_source/prebuild/TUF* 2>/dev/null | sed 's|^|    |'
  echo
  echo 'Arbeiten damit:'
  echo '  docker run -it --rm -v '$VOL':/src -w /src/asuswrt-merlin.ng ubuntu:24.04 bash'
"