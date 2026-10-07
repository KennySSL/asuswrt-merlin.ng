#!/bin/bash
# =============================================================================
# fetch-sources.sh -- holt mqvpn + Abhaengigkeiten in den asuswrt-Baum
#
# Aufruf (aus der Repo-Wurzel):
#   bash integration/fetch-sources.sh
#
# Legt alles nach release/src/router/ -- dort erwartet asuswrt seine
# Komponenten (vgl. ipset-7.6/ im Router-Makefile).
#
# REIHENFOLGE IST WICHTIG:
#   mqvpn zieht xquic als Submodul, xquic zieht BoringSSL als Submodul.
#   BoringSSL ist ein Submodul von xquic, NICHT von mqvpn. Wer die drei
#   einzeln klont, baut gegen die falsche Quelllage.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ROUTER="$ROOT/release/src/router"

# --- SDK pruefen: die V2 braucht 5.04axhnd.675x ---------------------------
SDK_FOUND=""
for d in "$ROOT"/release/src-rt-*; do
  [ -d "$d" ] || continue
  case "$(basename "$d")" in
    *5.04*axhnd.675x*) SDK_FOUND="$(basename "$d")" ;;
  esac
done
[ -n "$SDK_FOUND" ] || {
  echo "FEHLER: kein release/src-rt-5.04*axhnd.675x gefunden."
  echo "       Das ist das SDK der TUF-AX3000_V2. Vorhanden:"
  ls -d "$ROOT"/release/src-rt-* 2>/dev/null | sed 's|.*/|          |'
  exit 1
}
echo "==> SDK: $SDK_FOUND"

[ -d "$ROUTER" ] || { echo "FEHLER: $ROUTER fehlt"; exit 1; }
echo "==> Ziel: release/src/router"

# --- 1) libevent2 ---------------------------------------------------------
# mqvpn bricht ohne das hart ab: CMakeLists Zeile ~101 -> FATAL_ERROR.
# Nur Android kommt drumherum, dort ist ANDROID_CROSS_COMPILE gesetzt.
#
# ACHTUNG: es gibt auf github.com/libevent/libevent KEINEN Branch "stable".
# Der Branch hiess historisch so nur bei gitlab.com/libevent/libevent, und der
# GitLab-Smart-HTTP-Zugang blockt unauthentifizierte Abfragen. Deshalb hier
# fest auf den Release-Tag gepinnt -- das ist ohnehin reproduzierbarer.
if [ -d "$ROUTER/libevent2-2.1.12/.git" ]; then
  echo "==> [skip] libevent2-2.1.12"
else
  echo "==> [hole] libevent2 (release-2.1.12-stable)"
  LIBEVENT_OK=no
  for ref in release-2.1.12-stable master; do
    echo "    versuche Tag/Branch: $ref"
    if git clone --depth 1 --branch "$ref" \
         https://github.com/libevent/libevent.git "$ROUTER/libevent2-2.1.12" 2>&1; then
      LIBEVENT_OK=yes; break
    fi
    rm -rf "$ROUTER/libevent2-2.1.12"
  done
  [ "$LIBEVENT_OK" = yes ] || { echo "    FEHLER: libevent nicht klonbar"; exit 1; }
fi

# --- 2) mqvpn mit Submodulen --------------------------------------------
# --recurse-submodules holt in einem Zug:
#   third_party/xquic                      (Tencent QUIC, Multipath)
#   third_party/xquic/third_party/boringssl
#   third_party/lwip                       (nicht gebaut, aber vollstaendig)
if [ -d "$ROUTER/mqvpn/.git" ]; then
  echo "==> [skip] mqvpn"
  ( cd "$ROUTER/mqvpn" && git submodule update --init --recursive ) || true
else
  echo "==> [hole] mqvpn + Submodule (xquic, BoringSSL, lwip)"
  git clone --depth 1 --recurse-submodules https://github.com/mp0rta/mqvpn.git \
       "$ROUTER/mqvpn"
fi

# --- 3) Vollstaendigkeit pruefen ----------------------------------------
echo "==> Pruefung:"
ok=1
check(){ if [ -e "$1" ]; then echo "    OK      ${1#$ROUTER/}"; else
         echo "    FEHLT   ${1#$ROUTER/}"; ok=0; fi; }
check "$ROUTER/libevent2-2.1.12/configure"
check "$ROUTER/mqvpn/CMakeLists.txt"
check "$ROUTER/mqvpn/third_party/xquic/CMakeLists.txt"
check "$ROUTER/mqvpn/third_party/xquic/third_party/boringssl/CMakeLists.txt"

if [ $ok -eq 0 ]; then
  echo
  echo "FEHLER: Quellen unvollstaendig. Submodule nochmal:"
  echo "  cd $ROUTER/mqvpn && git submodule update --init --recursive"
  exit 1
fi

# --- 4) BoringSSL-Buildpfade fuer mqvpn.mk exportieren --------------------
# mqvpn.mk rechnet mit flachen Pfaden. Die schreiben wir hier einmal fest,
# damit es nicht auf einen festen Trunk-Stand angewiesen ist.
MQ="$ROUTER/mqvpn"
{
  echo "# --- automatisch von fetch-sources.sh erzeugt, nicht editieren ---"
  echo "MQVPN_DIR        := $MQ"
  echo "XQUIC_DIR        := $MQ/third_party/xquic"
  echo "BORINGSSL_DIR    := $MQ/third_party/xquic/third_party/boringssl"
  echo "LIBEVENT_DIR     := $ROUTER/libevent2-2.1.12"
} > "$ROOT/integration/paths.mk"
echo "    geschrieben: integration/paths.mk"

echo
echo "==> Groessen:"
du -sh "$ROUTER/libevent2-2.1.12" "$ROUTER/mqvpn" 2>/dev/null | sed 's|^|    |'
echo
echo "==> Naechster Schritt:"
echo "  cp integration/mqvpn.mk release/$SDK_FOUND/mqvpn.mk"
echo "  cp integration/paths.mk release/$SDK_FOUND/paths.mk"
echo "  cd release/$SDK_FOUND && bash ../../integration/apply-integration.sh"