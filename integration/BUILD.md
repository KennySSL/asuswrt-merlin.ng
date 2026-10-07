# TUF-AX3000 V2 — eigene Firmware mit WAN3 und mqvpn

Baut `mqvpn` direkt in den Asuswrt-Quellbaum. Kein Entware, kein USB-Stick,
kein Cross-Compiler-Gefrickel auf dem Router.

---

## Warum das die richtige Route ist

Dein OMR ist nicht an mqvpn gestorben, sondern an Issue #4363: beim Update
0.1069 → 0.1081 ging beim Wechsel **Shorewall → nftables** das IP-Forwarding
verloren. Der Tunnel stand, die Statusseite war grün, kein Byte kam durch.

Solange eine fremde Gegenstelle dein Routing anfasst, kann das wieder passieren.
Eine selbstgebaute Firmware macht das nicht — die ändert sich nur, wenn du sie
flashst.

---

## Drei Stufen. Höchstens eine风险stufe pro Durchlauf.

### Stufe 1 — Test im Container, **null Router-Risiko**

Baut mqvpn in exakt der Toolchain, die der Firmware-Build benutzt, und fährt
danach die E2E-Suite vom mqvpn-Team selbst.

```bash
cd integration
docker build -f Dockerfile.mqvpn-test -t mqvpn-test .

docker run --rm -it --privileged mqvpn-test            # alle 16 Tests
docker run --rm -it --privileged mqvpn-test multipath  # nur einer
```

Geprüft wird: baut es durch, ist es statisch gelinkt, und halten Multipath,
Failover, Flapping, Killswitch, Blackhole, NAT, Reinjection.

**Wenn hier etwas klemmt, merkst du es hier — nicht am Router.**

Getestete Tests (aus `mqvpn/scripts/`):

| Test | Prüft |
|---|---|
| `run_multipath_test.sh` | Multipath-Verhandlung, Kernfunktion |
| `run_wlb_test.sh` | Weighted Load Balancing = dein 85 %-Ziel |
| `run_dellink_test.sh` / `run_8paths_...` | Link weg, Rest läuft |
| `run_carrier_flap_test.sh` | Carrier flapping = dein Stabilitätstest |
| `run_reconnect_test.sh` | Wiederverbindung |
| `run_killswitch_test.sh` | Killswitch |
| `run_validation_blackhole_test.sh` | Blackhole-Erkennung |
| `run_nat_test.sh` | NAT |
| `run_reinjection_test.sh` | Packet-Reinjection |
| `run_backup_fec_test.sh` | Backup-Pfad + FEC |
| `run_control_api_test.sh` | Control-API |
| `run_route_gate_test.sh` | Routing-Gate |
| `test_multiclient_multipath.sh` | mehrere Clients |

---

### Stufe 2 — Firmware bauen

```bash
# 1. Quelle holen (DEV_fix_tuf = der Branch mit aktivem TUF-Support)
git clone --depth 1 --single-branch --branch DEV_fix_tuf \
  https://github.com/gnuton/asuswrt-merlin.ng.git
cd asuswrt-merlin.ng

# 2. Bausteine von mqvpn nach release/src/router/
bash integration/fetch-sources.sh

# 3. In den SDK-Ordner und mqvpn einhängen
cd release/src-rt-5.04axhnd.675x
cp ../../integration/mqvpn.mk ./mqvpn.mk
bash ../../integration/apply-integration.sh

# 4. Nur mqvpn bauen, Firmware noch nicht
make mqvpn-verify
```

Warum `src-rt-5.04axhnd.675x`: Das ist das SDK der **V2**. Die V1 nimmt
`src-rt-5.02axhnd.675x`. Der Build erkennt das an `pwd` und setzt intern
`HND_ROUTER_AX_6756`. Das falsche SDK = kein Boot.

---

### Stufe 3 — Flashen

⚠️ **Erst weiterlesen, bevor du hier bist.**

## Brick-Risiko, ehrlich

**Der ASUS-Firmware-Recovery-Tool funktioniert bei der TUF-AX3000 V2
nachweislich nicht zuverlässig** — im Forum steht, er bricht bei rund 79 %
ab. Das heißt: wenn du das Image brickt, ist der Router möglicherweise tot und
das Recovery-Tool rettet ihn nicht.

Damit:

| Regel | Warum |
|---|---|
| **Immer über das Web-UI flashen**, nicht per `nvram`/tftp | Das Web-UI prüft die Signatur und lehnt fremde Images ab |
| **Nur ein Image flashen, das du gebaut hast und verifiziert hast** | Ein abgeschnittenes oder beschädigtes Image brickt zuverlässig |
| **Vorher die aktuelle Firmware sichern** | `tar` über SSH, plus NVRAM-Dump |
| **Erst Stufe 1 und 2 durchlaufen lassen** | Dort kann nichts bricken |
| Board-ID **nicht** raten | Falsche `odmpid` → kein Boot, kein Recovery |

### Vor dem Flash sichern

```sh
nvram export > /tmp/nvram-backup.bin
dd if=/dev/mtd0 of=/tmp/mtd0.bin bs=65536     # nur wenn du weisst was du tust
```

---

## Was mqvpn auf dem Router tatsächlich braucht

| Komponente | Warum | Bemerkung |
|---|---|---|
| **libevent2** | CMake bricht sonst hart ab (`FATAL_ERROR`) | nur Android kommt drumherum |
| **BoringSSL** | TLS für den QUIC-Tunnel | statisch; auf Linux kein Go/NASM/Perl nötig |
| **xquic** | Tencent-QUIC, der Multipath-Kern | mit `XQC_ENABLE_BBR2/FEC/XOR=ON` |
| **mqvpn** | der Daemon selbst | statisch gelinkt |

Auf dem Router als **Client**: kein NAT, kein masquerade. Das erledigt die
Gegenstelle. mqvpn nimmt nur das TUN und die Routen.

---

## Noch offen: WAN3

Dual WAN der Firmware gibt **zwei** WAN-Slots. Der dritte ist eine echte
Code-Änderung im Baum und noch nicht geschrieben, weil ich die betroffenen
Dateien erst im geklonten Quellbaum verifizieren muss. Betroffen sind
mindestens:

- Netzwerk-/VLAN-Konfiguration der 675x-Switch
- Interface-Definition des dritten WAN
- Multi-WAN-UI (dritter Reiter)
- Failover-Logik von zwei auf drei Interfaces

**Loopback** (`lo`, interne `br0`-Adresse) bleibt unangetastet — das ist kein
Sonderfall, sondern Voraussetzung dafür, dass der Router die WAN-Interfaces
überhaupt als Quellen für geroutete Pakete akzeptiert.

Sobald der Clone durch ist, arbeite ich das mit echten Pfaden aus.

---

## Konfiguration danach

mqvpn läuft dann als Dienst auf dem Router, ein Pfad pro WAN:

```ini
[Server]
Address = <VPS-IP>:65443

[Auth]
Key = <PSK vom VPS>

[Multipath]
Scheduler = wlb          # NICHT minrtt — minrtt ist Failover, kein Bonding
Path = <wan1-dev>
Path = <wan2-dev>
BackupPath = <wan3-dev>
```

`minrtt` nimmt immer die niedrigste RTT und **aggregiert nichts**. Für dein
85 %-Ziel ist `wlb` zwingend.