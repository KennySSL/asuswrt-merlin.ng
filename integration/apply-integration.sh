#!/bin/bash
# =============================================================================
# apply-integration.sh -- haengt mqvpn in den asuswrt-Baum ein
#
# Idempotent: laesst sich mehrfach ausfuehren, erkennt eigene Markierungen.
# Verifiziert Anker und Pfade, bevor irgendetwas geschrieben wird.
#
# Aufruf (der Aufrufer steht im SDK-Verzeichnis, nicht in release/):
#   cd release/src-rt-5.04axhnd.675x
#   bash ../../integration/apply-integration.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# BUGFIX B1: vorher stand hier  ROUTER_MK="$(cd .. && pwd)/release/src/router/Makefile".
# Nachrechnung: der Aufrufer steht in <ROOT>/release/src-rt-5.04axhnd.675x,
# also liefert `cd ..` <ROOT>/release -- und `/release/src/router/Makefile`
# ergibt <ROOT>/release/release/src/router/Makefile. Das Verzeichnis gibt es
# nicht, das Skript bricht also immer beim Anker-Test ab.
# Korrekt ist <ROOT>/release/src/router/Makefile. Wir rechnen es aus $HERE,
# damit der Pfad unabhaengig vom Arbeitsverzeichnis des Aufrufers stimmt.
ROUTER_DIR="$ROOT/release/src/router"
ROUTER_MK="$ROUTER_DIR/Makefile"
MARK="## --- mqvpn integration (openmpctprouter/asuswrt) ---"

[ -f "$HERE/mqvpn.mk" ] || { echo "FEHLER: $HERE/mqvpn.mk fehlt"; exit 1; }
[ -f "$ROUTER_MK" ] || { echo "FEHLER: $ROUTER_MK nicht gefunden"; exit 1; }
echo "==> Router-Makefile: $ROUTER_MK"

# --- 0) SDK und Build-Profil verifizieren ------------------------------------
# Die Firmware heisst TUF-AX3000_V2, das *Profil* (ROM-Verzeichnis) ist aber
# 96756GW -- siehe release/src-rt/target.mak:490-491
#   export HND-96756_BASE := ... HND_ROUTER_AX_6756=y PROFILE="96756GW" ...
#   export TUF-AX3000_V2 := $(HND-96756_BASE)
# "tuf-ax3000_v2" existiert im targets/-Baum nicht, der Build laeuft ueber
# PROFILE=96756GW. Das Verzeichnis entsteht erst beim Bau (fs.install).
# Das Arbeitsverzeichnis IST das SDK-Verzeichnis (der Aufrufer macht vorher
# `cd release/src-rt-5.04axhnd.675x`). Also `pwd`, nicht `cd ..`.
SDK_DIR="$(pwd)"
PROFILE_DIR="$SDK_DIR/targets/96756GW"
[ -d "$PROFILE_DIR" ] \
  || { echo "FEHLER: $PROFILE_DIR fehlt -- falsches SDK? (erwartet src-rt-5.04axhnd.675x)"; exit 1; }
[ -f "$PROFILE_DIR/96756GW.TUF-AX3000_V2" ] \
  || { echo "FEHLER: Board-Datei 96756GW.TUF-AX3000_V2 fehlt in $PROFILE_DIR"; exit 1; }
echo "==> SDK: $(basename "$SDK_DIR")   Profil: 96756GW (fs.install entsteht beim Bau)"

# --- 1) mqvpn.mk (und paths.mk) neben das Makefile legen ----------------------
# Das `include mqvpn.mk` wird aus release/src/router/Makefile gelesen, also
# muss die Datei in release/src/router/ liegen -- nicht im SDK-Verzeichnis.
# $(TOP) ist common.mak:10 als $(SRCBASE)/router exportiert, zeigt also
# genau auf release/src/router. Damit ist der Include pfadunabhaengig vom cwd.
# Das Kopieren passiert VOR der Markierungs-Pruefung, damit ein erneuter
# Lauf auch eine aktualisierte mqvpn.mk einspielt.
install -m 0644 "$HERE/mqvpn.mk" "$ROUTER_DIR/mqvpn.mk"
echo "==> mqvpn.mk -> $ROUTER_DIR/mqvpn.mk"
if [ -f "$HERE/paths.mk" ]; then
  install -m 0644 "$HERE/paths.mk" "$ROUTER_DIR/paths.mk"
  echo "==> paths.mk -> $ROUTER_DIR/paths.mk"
else
  echo "==> paths.mk fehlt, mqvpn.mk nutzt die asuswrt-Vorgabe \$(TOP)"
fi

if grep -qF "$MARK" "$ROUTER_MK"; then
  echo "==> Integration ist bereits drin, nichts zu tun."
  exit 0
fi

# --- Anker pruefen ---------------------------------------------------------
A1='# Last rule: append openssl dir if used'
A2='www-install:'
for a in "$A1" "$A2"; do
  grep -qF "$a" "$ROUTER_MK" || { echo "FEHLER: Anker nicht gefunden: $a"; exit 1; }
done
echo "==> beide Anker gefunden"

cp "$ROUTER_MK" "$ROUTER_MK.pre-mqvpn"
echo "==> Backup: $ROUTER_MK.pre-mqvpn"

# --- 2) Komponente in obj-y registrieren ------------------------------------
# Muss VOR der openssl-Nachregel stehen: Makefile:1841-1842 leitet obj-clean
# und obj-install per foreach aus $(obj-y) ab. Alles, was dort nicht steht,
# wird weder gebaut noch installiert.
# Namen der Objekte = Namen der Ziele in mqvpn.mk (jeweils mit -install und
# -clean, weil obj-clean/obj-install daraus automatisch die Varianten machen).
TMP1="$(mktemp)"
awk -v mark="$MARK" -v a1="$A1" '
  index($0, a1) && !done {
    print mark
    print "ifeq ($(PROFILE),96756GW)"
    print "obj-y += libevent2-2.1.12"
    print "obj-y += boringssl"
    print "obj-y += xquic"
    print "obj-y += mqvpn"
    print "include $(TOP)/mqvpn.mk"
    print "endif"
    print ""
    done=1
  }
  { print }
' "$ROUTER_MK" > "$TMP1"
mv "$TMP1" "$ROUTER_MK"
echo "==> 1/2  obj-y registriert + mqvpn.mk eingebunden"

# --- 3) mqvpn-stage an die Install-Kette haengen ---------------------------
# `www` steht in obj-y (Makefile:999), also ruft `make install` ueber
# obj-install (Makefile:2052) www-install auf. www-install wird hier um
# mqvpn-stage als Voraussetzung ergaenzt -- eine echte Make-Abhaengigkeit,
# kein freistehendes Recipe. Bisher stand dort ein einzelnes `$(MAKE)
# mqvpn-stage` auf Top-Level: das ist kein gueltiges Make (Syntaxfehler
# "missing separator") und wurde nie ausgefuehrt.
TMP2="$(mktemp)"
awk -v a2="$A2" '
  $0 == a2 && !done { print "www-install: mqvpn-stage"; done=1; next }
  { print }
' "$ROUTER_MK" > "$TMP2"
mv "$TMP2" "$ROUTER_MK"
echo "==> 2/2  www-install von mqvpn-stage abhaengig gemacht"

# --- Kontrolle --------------------------------------------------------------
echo "==> Kontrolle:"
grep -nF "$MARK" "$ROUTER_MK" | sed 's|^|    |'
grep -n 'mqvpn\|libevent2-2.1.12\|boringssl\|xquic' "$ROUTER_MK" | sed 's|^|    |'

echo
echo "=== Naechster Schritt ==="
echo "  bash $HERE/fetch-sources.sh          # holt mqvpn + Submodule nach release/src/router"
echo "  cd $SDK_DIR && make TUF-AX3000_V2"
echo "  make -C router mqvpn-verify"
echo
echo "ACHTUNG: noch nicht flashen. Erst mqvpn-verify und danach die"
echo "WAN3-/Loopback-Konfiguration pruefen. Siehe BUILD.md."
