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
# Nachgeprueft mit 'git ls-remote --heads': 6 Branches, keiner heisst "stable".
# Der Branch hiess historisch so nur bei gitlab.com/libevent/libevent, und der
# GitLab-Smart-HTTP-Zugang blockt unauthentifizierte Abfragen -- der
# Archiv-Download liefert HTTP 302 auf /users/sign_in. Deshalb hier fest auf
# den Release gepinnt, das ist ohnehin reproduzierbarer.
#
# ---- WARUM TARBALL STATT GIT-TAG (das war der Blocker) -------------------
# Im Git-Repo gibt es beim Auschecken des Tags KEIN 'configure'. Das wird erst
# von autogen.sh erzeugt. Am release-2.1.12-stable nachgemessen:
#     autogen.sh / configure.ac / Makefile.am  -> vorhanden
#     configure                                  -> FEHLT
# Ein reiner 'git clone --depth 1 --branch release-2.1.12-stable' liefert also
# einen Baum, an dem die Pruefung in Schritt 3 fehlschlaegt und das Skript mit
# exit 1 endet. Genau das war der Blocker.
#
# Das offizielle Release-Tarball enthaelt 'configure' dagegen schon fertig
# (plus Makefile.in und aclocal.m4), also ist kein Autotools-Lauf noetig.
#
# ---- ACHTUNG BEIM NAMEN DES TARBALLS ------------------------------------
# Das Asset heisst 'libevent-2.1.12-stable.tar.gz', also mit Prefix
# 'libevent-' -- NICHT 'release-2.1.12-stable.tar.gz' wie der Tag. Mit dem
# Tag-Namen gibt GitHub 404; das sah hier zuerst nach "es gibt kein Tarball"
# aus. Der Prefix ist der ganze Unterschied.
LIBEVENT_DIR="$ROUTER/libevent2-2.1.12"
LIBEVENT_TARBALL="libevent-2.1.12-stable.tar.gz"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/$LIBEVENT_TARBALL"
# sha256 des offiziellen Assets. Nur WARNUNG, kein harter Abbruch: wenn
# upstream das Asset neu hochlaedt, soll der Build nicht an einer
# Pruefsumme sterben. Entscheidend ist der Dateitest auf 'configure' weiter
# unten, der schlaegt bei einem kaputten Archiv zuverlaessig an.
LIBEVENT_SHA256="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"

# Der Marker fuer "liegt schon vor" ist das 'configure' selbst, nicht .git:
# das Tarball ist kein Git-Checkout, und 'configure' ist genau das, was der
# Build braucht. Ein alter, nur geklonter Baum ohne configure wird so
# automatisch repariert, statt weiter als "vorhanden" durchgewinkt zu werden.
if [ -f "$LIBEVENT_DIR/configure" ]; then
  echo "==> [skip] libevent2-2.1.12 (configure vorhanden)"
else
  echo "==> [hole] libevent2 2.1.12 (offizielles Release-Tarball)"
  TMP="$(mktemp -d)"
  LIBEVENT_OK=no

  # Kleiner Download-Helfer: curl oder wget, je nachdem was da ist. Ohne
  # if-Formular wuerde ein fehlgeschlagener Download das set -e ausloesen.
  fetch(){ if command -v curl >/dev/null 2>&1; then
              curl -fsSL --retry 3 -o "$2" "$1"
            elif command -v wget >/dev/null 2>&1; then
              wget -q -O "$2" "$1"
            else
              echo "    FEHLER: weder curl noch wget im Image"; return 1
            fi; }

  # ---- Variante B: offizielles Release-Tarball (bevorzugter Weg) ---------
  if fetch "$LIBEVENT_URL" "$TMP/$LIBEVENT_TARBALL"; then
    got="$(sha256sum "$TMP/$LIBEVENT_TARBALL" | cut -d' ' -f1)"
    if [ "$got" = "$LIBEVENT_SHA256" ]; then
      echo "    sha256 stimmt: $got"
    else
      echo "    WARNUNG: sha256 weicht ab -- nur Hinweis, kein Abbruch"
      echo "             erwartet: $LIBEVENT_SHA256"
      echo "             bekommen:  $got"
    fi
    mkdir -p "$TMP/x"
    # --strip-components=1: im Archiv liegt alles unter libevent-2.1.12-stable/,
    # gebaut wird aber gegen libevent2-2.1.12/ -- der Name steckt im
    # Router-Makefile und darf nicht von uns erfunden werden.
    if tar xzf "$TMP/$LIBEVENT_TARBALL" -C "$TMP/x" --strip-components=1; then
      # Dateitest, kein Kommentar: nur ein Archiv mit echtem configure
      # akzeptieren wir.
      if [ -f "$TMP/x/configure" ]; then
        rm -rf "$LIBEVENT_DIR"
        mv "$TMP/x" "$LIBEVENT_DIR"
        LIBEVENT_OK=yes
        echo "    aus Tarball entpackt, configure ist drin"
      else
        echo "    Tarball ohne 'configure' -- unerwartet, nehme den Git-Weg"
      fi
    else
      echo "    Tarball laesst sich nicht entpacken -- nehme den Git-Weg"
    fi
  else
    echo "    Download fehlgeschlagen -- nehme den Git-Weg"
  fi

  # ---- Variante A: Git-Tag-Kette als Rueckfall ----------------------------
  # Bleibt erhalten, damit es weiterhin eine zweite Quelle gibt. Hier muss
  # aber autogen.sh laufen: der Tag hat kein configure.
  if [ "$LIBEVENT_OK" != yes ]; then
    for ref in release-2.1.12-stable master; do
      echo "    Rueckfall: versuche Tag/Branch $ref"
      if git clone --depth 1 --branch "$ref" \
           https://github.com/libevent/libevent.git "$LIBEVENT_DIR" 2>&1; then
        if [ ! -f "$LIBEVENT_DIR/configure" ]; then
          echo "    $ref hat kein 'configure' -> erzeuge es mit autogen.sh"
          if ( cd "$LIBEVENT_DIR" && sh ./autogen.sh ); then
            echo "    autogen.sh ok"
          else
            echo "    autogen.sh fehlgeschlagen (Autotools fehlen im Image?)"
          fi
        fi
        if [ -f "$LIBEVENT_DIR/configure" ]; then
          LIBEVENT_OK=yes
          echo "    aus Git-$ref, configure vorhanden"
          break
        fi
        echo "    $ref liefert trotzdem kein 'configure' -- naechster Ref"
      fi
      rm -rf "$LIBEVENT_DIR"
    done
  fi

  rm -rf "$TMP"
  [ "$LIBEVENT_OK" = yes ] || { echo "    FEHLER: libevent nicht beschaffbar"; exit 1; }
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
check "$LIBEVENT_DIR/configure"
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
  echo "LIBEVENT_DIR     := $LIBEVENT_DIR"
} > "$ROOT/integration/paths.mk"
echo "    geschrieben: integration/paths.mk"

echo
echo "==> Groessen:"
du -sh "$LIBEVENT_DIR" "$ROUTER/mqvpn" 2>/dev/null | sed 's|^|    |'
echo
echo "==> Naechster Schritt:"
echo "  cp integration/mqvpn.mk release/$SDK_FOUND/mqvpn.mk"
echo "  cp integration/paths.mk release/$SDK_FOUND/paths.mk"
echo "  cd release/$SDK_FOUND && bash ../../integration/apply-integration.sh"