#!/bin/bash
# =============================================================================
# run-tests.sh -- mqvpn Funktionstests im Container (Stufe 2)
#
# Nutzt die E2E-Suite aus dem mqvpn-Repo. Das sind die Tests, die die Leute
# selbst schreiben, die mqvpn gebaut haben -- kein selbstgebasteltes Zeug.
#
# Aufruf:
#   docker run --rm -it --privileged mqvpn-test            # alles
#   docker run --rm -it --privileged mqvpn-test multipath  # nur einer
# =============================================================================

MQVPN=/build/mqvpn/build/mqvpn
SRC=/build/mqvpn
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[ -x "$MQVPN" ] || { echo "FEHLER: $MQVPN nicht gebaut"; exit 1; }

# Die Skripte erwarten das Binary unter build/mqvpn -- liegt schon so.
# Manche Tests rufen 'mqvpn' per PATH, also verfuegbar machen.
export PATH="/build/mqvpn/build:$PATH"

declare -A TESTS=(
  [multipath]="$SRC/scripts/run_multipath_test.sh"
  [wlb]="$SRC/scripts/run_wlb_test.sh"
  [multiclient]="$SRC/scripts/test_multiclient_multipath.sh"
  [e2e]="$SRC/scripts/ci_e2e/run_test.sh"
  [failover]="$SRC/scripts/ci_e2e/run_dellink_test.sh"
  [failover8]="$SRC/scripts/ci_e2e/run_8paths_dellink_test.sh"
  [flap]="$SRC/scripts/ci_e2e/run_carrier_flap_test.sh"
  [reconnect]="$SRC/scripts/ci_e2e/run_reconnect_test.sh"
  [killswitch]="$SRC/scripts/ci_e2e/run_killswitch_test.sh"
  [blackhole]="$SRC/scripts/ci_e2e/run_validation_blackhole_test.sh"
  [nat]="$SRC/scripts/ci_e2e/run_nat_test.sh"
  [reinjection]="$SRC/scripts/ci_e2e/run_reinjection_test.sh"
  [backupfec]="$SRC/scripts/ci_e2e/run_backup_fec_test.sh"
  [controlapi]="$SRC/scripts/ci_e2e/run_control_api_test.sh"
  [routegate]="$SRC/scripts/ci_e2e/run_route_gate_test.sh"
  [throughput]="$SRC/scripts/ci_e2e/run_throughput_floor_test.sh"
)

run_one(){
  local name=$1 script=$2
  echo
  echo "################################################################"
  echo "# $name   ($script)"
  echo "################################################################"
  if [ ! -f "$script" ]; then
    echo "  SKIP -- Skript nicht vorhanden"
    return 0
  fi
  if [ ! -x "$script" ]; then chmod +x "$script" 2>/dev/null || true; fi
  if bash "$script" "$MQVPN" 2>&1 | tail -40; then
    echo "--- $name: DONE"
  else
    echo "--- $name: FEHLGESCHLAGEN (Exit $?)"
    FAILED=$((FAILED+1))
  fi
}

[ "$(id -u)" = 0 ] || { echo "braucht --privileged (netns + tc)"; exit 1; }
command -v ip >/dev/null || { echo "iproute2 fehlt"; exit 1; }
command -v tc >/dev/null || { echo "tc/netem fehlt"; exit 1; }
[ -c /dev/net/tun ] || { echo "/dev/net/tun fehlt"; exit 1; }

FAILED=0
say "Binary:"
ls -lh "$MQVPN"
file "$MQVPN" 2>/dev/null || true
"$MQVPN" --version 2>/dev/null || true
say "statisch verlinkt?"
if ldd "$MQVPN" 2>&1 | grep -q 'not a dynamic executable'; then
  echo "    ja -- keine Laufzeit-Abhaengigkeiten"
else
  echo "    nein -- haengt an:"
  ldd "$MQVPN" 2>&1 | head -8
fi

if [ "$1" = "all" ] || [ -z "$1" ]; then
  # Reihenfolge = Kosten. Multipath zuerst (der Kern), dann Failover-Familie,
  # dann die Randfaelle.
  for t in multipath wlb failover failover8 flap reconnect killswitch \
           blackhole controlapi routegate nat reinjection backupfec \
           multiclient throughput e2e; do
    [ -n "${TESTS[$t]:-}" ] && run_one "$t" "${TESTS[$t]}"
  done
else
  [ -n "${TESTS[$1]:-}" ] || { echo "unbekannter Test: $1"; echo "verfuegbar: ${!TESTS[*]}"; exit 1; }
  run_one "$1" "${TESTS[$1]}"
fi

echo
echo "################################################################"
echo "# FEHLGESCHLAGEN: $FAILED"
echo "################################################################"
exit $(( FAILED > 0 ))