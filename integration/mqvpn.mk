# =============================================================================
# mqvpn.mk -- Build-Regeln fuer mqvpn (+ libevent2, BoringSSL, xquic)
#
# Wird von apply-integration.sh nach release/src/router/mqvpn.mk kopiert und
# aus release/src/router/Makefile (Anker "# Last rule: append openssl dir if
# used", Zeile 1834) per `include $(TOP)/mqvpn.mk` eingebunden.
#
# Reihenfolge ist hier entscheidend: obj-clean und obj-install werden im
# Router-Makefile erst in Zeile 1841/1842 per foreach aus $(obj-y) abgeleitet.
# Alles, was dort nicht steht, wird weder gebaut noch installiert -- die
# Registrierung im obj-y muss also VOR Zeile 1841 stehen.
#
# Ab dem Einbindepunkt sind die asuswrt-Variablen exportiert und benutzbar:
#   $(TOP)            common.mak:10   = $(SRCBASE)/router (= release/src/router)
#   $(HND_SRC)        router/Makefile:31, absolut
#   $(INSTALLDIR)     common.mak:88   = targets/$(PROFILE)/fs.install
#   $(CC)/$(CXX)/$(AR)/$(RANLIB)  common.mak:42-45
#   $(STRIP)          common.mak:60,  $(READELF) common.mak:56
#   $(CONFIGURE)      platform.mak:32 = ./configure LD=... --host=arm-buildroot-...
#   $(PARALLEL_BUILD) platform.mak:667 = -j<Anzahl CPU>
#
# Das Idiom ist der ipset-7.6-Block aus release/src/router/Makefile:3069-3095:
#   <name>/configure -> <name>/Makefile -> <name> -> <name>-install -> <name>-clean
# ipset holt seine Abhaengigkeit libmnl-1.0.4 als Voraussetzung von `ipset-7.6`
# und findet sie ueber -I/-L. Genauso werden hier libevent2, BoringSSL und xquic
# gebaut, und das jeweils naechste Ziel nimmt die Artefakte als echte
# Datei-Voraussetzung auf. Dadurch ist der Build idempotent: ein zweites
# `make all` baut nichts neu.
#
# KRITISCH -- nicht selbst entscheiden, das ist dokumentierter Fehler #4363
# (OMR 0.1069 -> 0.1081): Routing ging verloren, VPN-Stillstand mit gruener
# Statusanzeige. Jede Aenderung hier muss nach dem Bau geprueft werden.
# =============================================================================

# Pfade kommen aus paths.mk, das fetch-sources.sh neben mqvpn.mk ablegt.
# Fehlt die Datei, gelten die asuswrt-Vorgaben.
# Wichtig: NIE `$(shell pwd)` plus `release/src/router/`. Wenn das Router-
# Makefile laeuft, IST das Arbeitsverzeichnis bereits .../release/src/router --
# das ergaebe release/src/router/release/src/router (Pfadverdopplung).
# $(TOP) ist die vom Baum selbst exportierte Variable fuer genau dieses
# Verzeichnis, und $(HND_SRC) das absolute SDK-Verzeichnis.
-include $(TOP)/paths.mk
MQVPN_DIR         ?= $(TOP)/mqvpn
XQUIC_DIR         ?= $(MQVPN_DIR)/third_party/xquic
BORINGSSL_DIR     ?= $(XQUIC_DIR)/third_party/boringssl
LIBEVENT_DIR      ?= $(TOP)/libevent2-2.1.12

# Alles Gebaute liegt ausserhalb des versionierten Quellbaums: $(HND_SRC) ist
# release/src-rt-5.04axhnd.675x, also landet nichts in .git. Im Nicht-HND-Fall
# (HND_SRC leer) greift $(TOP) -- dann gibt es auch keinen $(INSTALLDIR)/<name>,
# in den der BoringSSL-Output nuetzen wuerde.
MQVPN_BUILD_ROOT  ?= $(if $(HND_SRC),$(HND_SRC)/mqvpn-build,$(TOP)/mqvpn-build)
LIBEVENT_PREFIX   ?= $(MQVPN_BUILD_ROOT)/deps
BORINGSSL_OUT     ?= $(MQVPN_BUILD_ROOT)/boringssl
XQUIC_OUT         ?= $(MQVPN_BUILD_ROOT)/xquic
MQVPN_BUILD       ?= $(MQVPN_BUILD_ROOT)/mqvpn

# mqvpn liest BORINGSSL_BUILD_DIR und prueft ${BORINGSSL_BUILD_DIR}/ssl/libssl.a
# (CMakeLists.txt:205-213). Genau diese beiden Dateien erzeugt der BoringSSL-
# Build in $(BORINGSSL_OUT) -- deshalb wird das Verzeichnis unveraendert
# durchgereicht und nichts kopiert.
BORINGSSL_LIB     = $(BORINGSSL_OUT)/ssl/libssl.a
BORINGSSL_CRYPTO  = $(BORINGSSL_OUT)/crypto/libcrypto.a
XQUIC_STATIC      = $(XQUIC_OUT)/libxquic-static.a
XQUIC_SHARED      = $(XQUIC_OUT)/libxquic.so
LIBEVENT_LIB      = $(LIBEVENT_PREFIX)/lib/libevent.a
LIBEVENT_HDR      = $(LIBEVENT_PREFIX)/include/event2/event.h
MQVPN_BIN         = $(MQVPN_BUILD)/mqvpn

MQVPN_CC          ?= $(CC)
MQVPN_CFLAGS      ?= -Os -fPIC -ffunction-sections -fdata-sections $(EXTRACFLAGS)
# -static: asuswrt liefert im ROM keine passende glibc fuer ein fremdes Binary.
# Das setzt libc.a/libstdc++.a der Toolchain voraus; falls der Cross-Gcc sie
# nicht mitbringt, MQVPN_LDFLAGS beim Aufruf ueberschreiben.
# EXTRALDFLAGS wird hier bewusst NICHT angehaengt: das SDK setzt es auf
# "-lgcc_s", und ein statischer Link hat kein libgcc_s (nur die dynamische
# Variante). Das liess schon CMakes Compilertest mit "cannot find -lgcc_s"
# scheitern.
MQVPN_LDFLAGS     ?= -Wl,--gc-sections -static

# -----------------------------------------------------------------------------
# 1) libevent2 -- mqvpn bricht ohne das hart ab.
#
#    B5: mqvpn/CMakeLists.txt:99-103 (Linux-Zweig):
#         find_path(EVENT_INCLUDE_DIR event2/event.h)
#         find_library(EVENT_LIB event)
#         if(NOT EVENT_LIB)
#             message(FATAL_ERROR "libevent not found. Install: apt install libevent-dev")
#    find_library durchsucht <prefix>/lib und <prefix>/lib64 -- nicht
#    <prefix>/usr/lib. Die alte Regel installierte per --prefix=/usr und
#    DESTDIR=... nach <deps>/usr/lib; find_library fand dort nichts und die
#    Konfiguration brach mit FATAL_ERROR ab.
#    Loesung: libevent wird direkt mit --prefix=$(LIBEVENT_PREFIX) installiert.
#    Dann liegen die Header in $(LIBEVENT_PREFIX)/include/event2/event.h und
#    libevent.a in $(LIBEVENT_PREFIX)/lib/libevent.a -- genau die beiden
#    Stellen, an denen find_path und find_library suchen. -DCMAKE_PREFIX_PATH
#    zeigt mqvpn in Schritt 4 darauf. Kein Suchpfad-Flag, das CMake nur
#    verbiegt: der Prefix IST der Ort, an dem installiert wird.
#
#    Nur die Kern-Teile, kein OpenSSL -- TLS macht BoringSSL.
# -----------------------------------------------------------------------------
libevent2-2.1.12/configure:
	cd $(LIBEVENT_DIR) && ./autogen.sh

libevent2-2.1.12/Makefile: libevent2-2.1.12/configure
	cd $(LIBEVENT_DIR) && \
	$(CONFIGURE) \
		--prefix=$(LIBEVENT_PREFIX) \
		--disable-openssl --disable-samples --disable-tests \
		--disable-libevent-regress \
		--enable-static --disable-shared --with-pic

# Der Stamp beweist: configure, make UND make install sind durch. Ohne ihn
# wuerde ein zweiter Lauf configure wiederholen, nur weil die Artefakte schon
# da sind -- und libevent-2.1.12-clean setzt das Makefile wieder zurueck.
$(LIBEVENT_PREFIX)/.libevent-built: libevent2-2.1.12/Makefile
	$(MAKE) -C $(LIBEVENT_DIR)
	$(MAKE) -C $(LIBEVENT_DIR) install
	@test -f $(LIBEVENT_LIB) || { echo "FEHLT: $(LIBEVENT_LIB)"; exit 1; }
	@test -f $(LIBEVENT_HDR) || { echo "FEHLT: $(LIBEVENT_HDR)"; exit 1; }
	@touch $@

$(LIBEVENT_LIB) $(LIBEVENT_HDR): $(LIBEVENT_PREFIX)/.libevent-built
	@test -f $@ || { echo "FEHLT: $@ (mqvpn-build clean?)"; exit 1; }

# WICHTIG: Die vier Sammelziele unten haben bewusst ein leeres Rezept (@:).
# Ohne Rezept zieht make das generische "%:"-Muster des SDK-Makefiles heran
# (router/Makefile:10121). Das fand release/src/router/mqvpn/ (ein
# CMake-Projekt ohne Makefile) und rief "./configure" auf -> Error 127,
# NACHDEM mqvpn schon fertig gebaut war.

# Das Objekt in obj-y. Es traegt die Abhaengigkeit, damit mqvpn nicht selbst
# raten muss, woher libevent kommt.
libevent2-2.1.12: $(LIBEVENT_LIB) $(LIBEVENT_HDR)
	@:

# obj-install (Makefile:1842) ruft fuer jedes obj-y `<name>-install` auf. mqvpn
# ist statisch gelinkt, im ROM wird die .a nicht gebraucht -- die Regel
# existiert nur, damit obj-install nicht ins Leere greift, und sagt das laut.
libevent2-2.1.12-install:
	@echo "  SKIP  libevent2-2.1.12-install (Link-Zeit-Abhaengigkeit, statisch in mqvpn gelinkt)"

libevent2-2.1.12-clean:
	[ ! -f $(LIBEVENT_DIR)/Makefile ] || $(MAKE) -C $(LIBEVENT_DIR) distclean
	rm -rf $(LIBEVENT_PREFIX)

# -----------------------------------------------------------------------------
# 2) BoringSSL -- statisch, nur ssl+crypto. Auf Linux kein Go/NASM/Perl noetig.
# -----------------------------------------------------------------------------
$(BORINGSSL_OUT)/.boringssl-built:
	# BoringSSL setzt fuer GCC hart -Werror -Wformat=2 -Wformat-signedness ...
	# (CMakeLists.txt, C_CXX_WARNINGS). Mit GCC 9.2 auf 32-Bit-ARM ist das nie
	# gegen genau diese Toolchain getestet worden -- eine Warnung waere ein
	# Abbruch. Warnungen bleiben sichtbar, brechen aber nichts ab.
	sed -i 's/C_CXX_WARNINGS -Werror /C_CXX_WARNINGS /' $(BORINGSSL_DIR)/CMakeLists.txt
	@if grep -q "C_CXX_WARNINGS -Werror" $(BORINGSSL_DIR)/CMakeLists.txt; then echo "FEHLER: -Werror in BoringSSL noch aktiv"; exit 1; fi
	mkdir -p $(BORINGSSL_OUT)
	cd $(BORINGSSL_OUT) && \
	CC="$(MQVPN_CC)" CXX="$(CXX)" AR=$(AR) RANLIB=$(RANLIB) \
	CFLAGS="$(MQVPN_CFLAGS)" CXXFLAGS="$(MQVPN_CFLAGS)" \
	cmake $(BORINGSSL_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_TESTING=OFF >/dev/null
	$(MAKE) -C $(BORINGSSL_OUT) $(PARALLEL_BUILD) ssl crypto >/dev/null
	# Neuere BoringSSL-Staende legen libssl.a/libcrypto.a ins Build-Wurzelverzeichnis
	# (ssl und crypto sind Top-Level-Targets ohne eigenes Ausgabeverzeichnis);
	# aeltere in ssl/ und crypto/. Unten wird ssl/ und crypto/ erwartet --
	# mqvpns CMake kennt beide Layouts, xquic bekommt die Pfade von hier.
	mkdir -p $(BORINGSSL_OUT)/ssl $(BORINGSSL_OUT)/crypto
	[ -f $(BORINGSSL_LIB) ] || cp -f $(BORINGSSL_OUT)/libssl.a $(BORINGSSL_LIB)
	[ -f $(BORINGSSL_CRYPTO) ] || cp -f $(BORINGSSL_OUT)/libcrypto.a $(BORINGSSL_CRYPTO)
	@test -f $(BORINGSSL_LIB) || { echo "FEHLT: $(BORINGSSL_LIB)"; exit 1; }
	@test -f $(BORINGSSL_CRYPTO) || { echo "FEHLT: $(BORINGSSL_CRYPTO)"; exit 1; }
	@touch $@

$(BORINGSSL_LIB) $(BORINGSSL_CRYPTO): $(BORINGSSL_OUT)/.boringssl-built
	@test -f $@ || { echo "FEHLT: $@ (mqvpn-build clean?)"; exit 1; }

boringssl: $(BORINGSSL_LIB) $(BORINGSSL_CRYPTO)
	@:

# Reines Link-Zeit-Artefakt: mqvpn bindet ssl+crypto statisch ein, im ROM
# darf davon nichts liegen.
boringssl-install:
	@echo "  SKIP  boringssl-install (Link-Zeit-Abhaengigkeit, statisch in mqvpn gelinkt)"

boringssl-clean:
	rm -rf $(BORINGSSL_OUT)

# -----------------------------------------------------------------------------
# 3) xquic -- FEC und XOR sind Pflicht fuer den Scheduler "backup_fec",
#    BBR2 macht aus den WANs ueberhaupt erst Bonding.
#
#    Die Abhaengigkeit auf BoringSSL ist keine Dekoration: xquic linkt gegen
#    libssl.a/libcrypto.a, und xquic/CMakeLists.txt:87-91 prueft jedes Element
#    von SSL_LIB_PATH auf Existenz und meldet sonst FATAL_ERROR. Deshalb werden
#    hier die .a-Dateien selbst uebergeben, nicht ihr Verzeichnis -- die alte
#    Regel hat das Verzeichnis $(STAGEDIR)/mqvpn-deps/ssl gegeben.
#    Die zweite, indirekte Abhaengigkeit ist mqvpn: xquics configure_file
#    (CMakeLists.txt:129-131) erzeugt include/xquic/xqc_configure.h im Quellbaum,
#    und mqvpn includiert genau diese Datei (XQUIC_INCLUDE_DIR,
#    mqvpn/CMakeLists.txt:46). Also muss xquic mindestens konfiguriert sein,
#    bevor mqvpn konfiguriert.
# -----------------------------------------------------------------------------
$(XQUIC_OUT)/.xquic-built: $(BORINGSSL_LIB)
	# xquic haengt -Werror erst NACH unserem CFLAGS an (CMakeLists.txt:109/113);
	# ein -Wno-error in CFLAGS wird daher uebersteuert. Direkt entfernen.
	sed -i 's/"-Werror -Wno-unused/"-Wno-unused/' $(XQUIC_DIR)/CMakeLists.txt
	@if grep -q "\"-Werror" $(XQUIC_DIR)/CMakeLists.txt; then echo "FEHLER: -Werror in xquic noch aktiv"; exit 1; fi
	mkdir -p $(XQUIC_OUT)
	cd $(XQUIC_OUT) && \
	CC="$(MQVPN_CC)" CXX="$(CXX)" AR=$(AR) RANLIB=$(RANLIB) \
	CFLAGS="$(MQVPN_CFLAGS)" CXXFLAGS="$(MQVPN_CFLAGS)" \
	cmake $(XQUIC_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DSSL_TYPE=boringssl \
		-DSSL_PATH=$(BORINGSSL_DIR) \
		-DSSL_INC_PATH=$(BORINGSSL_DIR)/include \
		-DSSL_LIB_PATH="$(BORINGSSL_LIB);$(BORINGSSL_CRYPTO)" \
		-DXQC_ENABLE_TESTING=OFF \
		-DXQC_ENABLE_BBR2=ON \
		-DXQC_ENABLE_FEC=ON \
		-DXQC_ENABLE_XOR=ON >/dev/null
	$(MAKE) -C $(XQUIC_OUT) $(PARALLEL_BUILD) >/dev/null
	@test -f $(XQUIC_STATIC) || { echo "FEHLT: $(XQUIC_STATIC)"; exit 1; }
	@test -f $(XQUIC_SHARED) || { echo "FEHLT: $(XQUIC_SHARED)"; exit 1; }
	@touch $@

$(XQUIC_STATIC) $(XQUIC_SHARED): $(XQUIC_OUT)/.xquic-built
	@test -f $@ || { echo "FEHLT: $@ (mqvpn-build clean?)"; exit 1; }

xquic: $(XQUIC_STATIC) $(XQUIC_SHARED)
	@:

xquic-install:
	@echo "  SKIP  xquic-install (Link-Zeit-Abhaengigkeit, statisch in mqvpn gelinkt)"

xquic-clean:
	rm -rf $(XQUIC_OUT)

# -----------------------------------------------------------------------------
# 4) mqvpn
#    -DXQUIC_BUILD_DIR      mqvpn/CMakeLists.txt:48-79: damit importiert mqvpn
#                           xquic als SHARED (libxquic.so) und -- falls
#                           vorhanden -- xquic-static als STATIC. xquic-static
#                           wird bevorzugt (Zeile 186-190), also statisch gelinkt.
#    -DBORINGSSL_BUILD_DIR  B4: mqvpn/CMakeLists.txt:193-223 liest genau diese
#                           Variable und sonst nichts. SSL_LIB_PATH und
#                           SSL_INC_PATH kommen in mqvpns CMakeLists.txt kein
#                           einziges Mal vor -- die gehoeren zu xquic
#                           (third_party/xquic/CMakeLists.txt:64-98), wo sie
#                           in Schritt 3 korrekt gesetzt werden.
#    -DCMAKE_PREFIX_PATH    zeigt auf den libevent-Prefix aus Schritt 1, damit
#                           find_path/find_library libevent finden.
#    -DBUILD_TESTING=OFF    spart die Testprogramme (CMakeLists.txt:856-857).
#    -DMQVPN_ENABLE_HYBRID_TCP_LANE=OFF
#                           lwIP-Hybrid wird fuer den Router nicht gebraucht.
#                           ANDROID_CROSS_COMPILE zu setzen waere der andere Weg,
#                           die libevent-Pflicht zu umgehen (CMakeLists.txt:88),
#                           aber das Flag schaltet auch CLI und Bind-Layer ab.
# -----------------------------------------------------------------------------
$(MQVPN_BIN): $(LIBEVENT_LIB) $(LIBEVENT_HDR) $(XQUIC_STATIC) $(XQUIC_SHARED)
	mkdir -p $(MQVPN_BUILD)
	cd $(MQVPN_BUILD) && \
	CC="$(MQVPN_CC)" CXX="$(CXX)" AR=$(AR) RANLIB=$(RANLIB) STRIP=$(STRIP) \
	CFLAGS="$(MQVPN_CFLAGS)" CXXFLAGS="$(MQVPN_CFLAGS)" \
	cmake $(MQVPN_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DXQUIC_BUILD_DIR=$(XQUIC_OUT) \
		-DBORINGSSL_BUILD_DIR=$(BORINGSSL_OUT) \
		-DCMAKE_PREFIX_PATH=$(LIBEVENT_PREFIX) \
		-DBUILD_TESTING=OFF \
		-DMQVPN_ENABLE_HYBRID_TCP_LANE=OFF \
		-DCMAKE_EXE_LINKER_FLAGS="$(MQVPN_LDFLAGS)" >/dev/null
	$(MAKE) -C $(MQVPN_BUILD) $(PARALLEL_BUILD) mqvpn >/dev/null
	@test -x $(MQVPN_BIN) || { echo "FEHLT: $(MQVPN_BIN)"; exit 1; }

mqvpn: $(MQVPN_BIN)
	@:

# mqvpn-stage: legt das fertige Binary in das Installationsverzeichnis. Das ist
# die Stufe, die apply-integration.sh an www-install: haengt.
#
# Warum nicht der generische %-stage-Mechanismus (Makefile:10125)? Der laeuft
# `make install DESTDIR=$(STAGEDIR)` im Quellverzeichnis -- mqvpn ist aber ein
# CMake-Projekt ohne Makefile im Quellbaum. Und $(STAGEDIR)/usr/lib ist der
# gemeinsame Ort, an dem busybox (Makefile:2848), dropbear (5298) und
# tcpreplay per -L nachschauen; ein VPN-Binary gehoert dort nicht hin.
# Der Ort fuer ROM-Inhalte ist $(INSTALLDIR)/<obj-y-name>/: genau daraus tar't
# gen_target (Makefile:2260) in das Image. Also heisst stage hier: ins
# Installationsverzeichnis legen, gestrippt.
mqvpn-stage: mqvpn
	install -D -m 0755 $(MQVPN_BIN) $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn
	$(STRIP) $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn
	@echo "  OK    mqvpn -> $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn"

# Statisch gelinkt: weder libevent.a noch ssl/crypto muessen ins ROM. Die drei
# Abhaengigkeiten werden gebaut, aber nicht ausgeliefert.
mqvpn-install: mqvpn-stage
	@test -x $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn || \
		{ echo "FEHLT: $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn"; exit 1; }

mqvpn-clean: libevent2-2.1.12-clean boringssl-clean xquic-clean
	rm -rf $(MQVPN_BUILD)

# -----------------------------------------------------------------------------
# Nach dem Build MUSS geprueft werden (Fehlerklasse 4363):
#   * ip_forward ist 1
#   * WAN3-Interface existiert und ist UP
#   * Routing zwischen LAN und allen drei WANs stimmt
# -----------------------------------------------------------------------------
mqvpn-verify:
	@echo "--- mqvpn binary ---"
	@test -x $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn || \
		{ echo "FEHLT: $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn"; exit 1; }
	@file $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn 2>/dev/null || true
	@echo "--- Abhaengigkeiten (sollte statisch sein) ---"
	@$(READELF) -d $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn 2>&1 | head -3 || true
	@echo "OK: mqvpn liegt im ROM"
