#!/bin/bash
# =============================================================================
# apply-integration.sh -- haengt mqvpn in den asuswrt-Baum ein
#
# Idempotent: laesst sich mehrfach ausfuehren, erkennt eigene Markierungen.
# Verifiziert Anker, bevor irgendetwas geschrieben wird.
#
# Aufruf:
#   cd release/src-rt-5.04axhnd.675x
#   bash ../../integration/apply-integration.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROUTER_MK="$(cd .. && pwd)/release/src/router/Makefile"
MARK="## --- mqvpn integration (openmpctprouter/asuswrt) ---"

[ -f "$ROUTER_MK" ] || { echo "FEHLER: $ROUTER_MK nicht gefunden"; exit 1; }
echo "==> Router-Makefile: $ROUTER_MK"

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

# --- 1) Komponente in obj-y registrieren ------------------------------------
# Muss VOR der openssl-Nachregel stehen, sonst greift die Sortierung nicht.
TMP1="$(mktemp)"
awk -v mark="$MARK" '
  index($0, "'"$A1"'") && !done {
    print mark
    print "obj-$(HND_ROUTER_AX_6756) += libevent2-2.1.12"
    print "obj-$(HND_ROUTER_AX_6756) += boringssl"
    print "obj-$(HND_ROUTER_AX_6756) += xquic"
    print "obj-$(HND_ROUTER_AX_6756) += mqvpn"
    print "include $(shell pwd)/mqvpn.mk"
    print ""
    done=1
  }
  { print }
' "$ROUTER_MK" > "$TMP1"
mv "$TMP1" "$ROUTER_MK"
echo "==> 1/2  obj-y registriert + mqvpn.mk eingebunden"

# --- 2) -stage-Ziele der Abhaengigkeiten an die Hauptbuild-Kette haengen ----
# `all:` haengt an $(obj-postlibs) bzw. $(obj-y). Die -stage-Ziele rufen wir
# ueber eine Pra-Bedingung auf, sonst baut mqvpn gegen noch leere Libs.
TMP2="$(mktemp)"
awk -v mark="$MARK" -v stage=1 '
  index($0, "'"$A2"'") && !done {
    print "ifeq ($(filter mqvpn, $(obj-y)),y)"
    print "ifneq ($(wildcard mqvpn.mk),)"
    print "\$(MAKE) mqvpn-stage"
    print "endif"
    print "endif"
    print ""
    done=1
  }
  { print }
' "$ROUTER_MK" > "$TMP2"
mv "$TMP2" "$ROUTER_MK"
echo "==> 2/2  mqvpn-stage an die Build-Kette gehaengt"

# --- Kontrolle --------------------------------------------------------------
echo "==> Kontrolle:"
grep -nF "$MARK" "$ROUTER_MK" | sed 's|^|    |'
grep -n 'mqvpn' "$ROUTER_MK" | sed 's|^|    |'

echo
echo "=== Naechster Schritt ==="
echo "  cp $HERE/mqvpn.mk ./mqvpn.mk"
echo "  bash $HERE/fetch-sources.sh"
echo "  make mqvpn-verify"
echo
echo "ACHTUNG: noch nicht flashen. Erst mqvpn-verify und danach die"
echo "WAN3-/Loopback-Konfiguration pruefen. Siehe BUILD.md."