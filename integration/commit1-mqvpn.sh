#!/bin/bash
# =============================================================================
# commit1-mqvpn.sh -- Committet die mqvpn-Integration in den asuswrt-Baum
#
# Laeuft IM Container (Linux), wo der Baum liegt. Auf Windows geht das nicht:
#   * release/src/router/udev/test/.../pci0000:00/0000:00:1e.0/vendor
#     -> Doppelpunkte sind auf Windows illegale Dateinamen
#   * .../nouveau/nvkm/subdev/i2c/aux.c
#     -> AUX ist auf Windows ein reservierter Geraetenamen, auch mit Endung
#
# Env:
#   GITHUB_TOKEN   zum Pushen
#   REPO_SLUG      z.B. KennySSL/asuswrt-merlin.ng
#   BRANCH         DEV_fix_tuf
# ============================================================================
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN fehlt}"
: "${REPO_SLUG:?REPO_SLUG fehlt}"
BRANCH=${BRANCH:-DEV_fix_tuf}
TREE=/src/asuswrt-merlin.ng
SRC=/src/integration          # integration/ auf dem Windows-Desktop, gemountet

say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[ -d "$TREE/.git" ] || { echo "FEHLER: $TREE/.git fehlt"; exit 1; }
[ -d "$SRC" ]       || { echo "FEHLER: $SRC fehlt (integration/ nicht gemountet)"; exit 1; }

cd "$TREE"
git config user.name  "KennySSL"
git config user.email "kenny.jahnke93@googlemail.com"

# --- Remote mit Token, ohne ihn in die Ausgabe zu leaken -------------------
git remote set-url origin \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_SLUG}.git"

say "Aktueller Branch: $(git rev-parse --abbrev-ref HEAD)  $(git log -1 --format=%h)"

# --- 1) integration/ in den Baum kopieren ----------------------------------
say "integration/ ablegen"
rm -rf "$TREE/integration"
mkdir -p "$TREE/integration"
cp -a "$SRC"/. "$TREE/integration"/ 2>/dev/null || true
find "$TREE/integration" -type f | sed "s|$TREE/|    |"

# --- 2) CI-Workflow --------------------------------------------------------
say "Workflow ablegen"
mkdir -p "$TREE/.github/workflows"
cp "$SRC/ci-mqvpn.yml" "$TREE/.github/workflows/ci-mqvpn.yml"

# --- 3) Commit ------------------------------------------------------------
git add integration .github/workflows/ci-mqvpn.yml
if git diff --cached --quiet; then
  say "nichts zu committen"
else
  git commit -q -F - <<'EOF'
mqvpn als Firmware-Komponente integrieren (TUF-AX3000_V2)

Baut mqvpn direkt in den asuswrt-Baum statt es zur Laufzeit nachzuladen.
Ziel ist die TUF-AX3000_V2 (SDK src-rt-5.04axhnd.675x).

Warum das so gebaut wird: das Routing des OMR-VPS ist beim Update
0.1069 -> 0.1081 verloren gegangen (Issue #4363, Shorewall -> nftables).
Tunnel stand, Statusseite gruen, kein Byte kam durch. Eine selbstgebaute
Firmware aendert ihr Routing nur, wenn sie geflasht wird.

Vier Bausteine, in dieser Reihenfolge:
  libevent2  mqvpn bricht ohne das hart ab (CMakeLists FATAL_ERROR);
             nur Android kommt darum herum
  BoringSSL  statisch; auf Linux kein Go/NASM/Perl noetig
  xquic      Tencent QUIC, der Multipath-Kern; XQC_ENABLE_BBR2/FEC/XOR
  mqvpn      der Daemon; statisch gelinkt

Build-Kette folgt dem asuswrt-Idiom (vgl. ipset-7.6):
  <name>/configure, <name>/Makefile, <name>, <name>-install, <name>-clean
Registrierung laeuft ueber obj-y, daraus erzeugt das Makefile automatisch
die -install-Ziele.

mqvpn-verify prueft, ob das Binary im ROM liegt -- vor dem Flashen zu
pruefen, sonst baue ich eine Stock-Firmware ohne mqvpn.

CI baut nur ein Modell statt der 16er-Matrix und laedt das Image als
Artifact hoch.
EOF
  say "Commit: $(git log -1 --format='%h %s')"
fi

# --- 4) Push ---------------------------------------------------------------
say "Push nach $REPO_SLUG @ $BRANCH"
git push origin "$BRANCH" 2>&1 | sed 's/x-access-token:[^@]*@/***@/'
say "Ergebnis: $(git log -1 --format=%h) auf origin/$BRANCH"

# Token aus der Remote-URL entfernen, damit er nicht im .git landet
git remote set-url origin "https://github.com/${REPO_SLUG}.git"
say "Fertig. CI laeuft an -> Actions-Tab im Fork."