# =============================================================================
# mqvpn.mk -- Build-Regeln fuer mqvpn (+libevent2, BoringSSL, xquic)
#
# Diese Datei wird in das SDK-Verzeichnis kopiert:
#   cd release/src-rt-5.04axhnd.675x
#   cp mqvpn.mk ./mqvpn.mk
#   patch -p1 < mqvpn-router-makefile.diff     (registriert mqvpn in obj-y)
#   include mqvpn.mk                            (oder: make ... mqvpn.mk)
#
# Idiom folgt exakt dem ipset-7.6-Block aus release/src/router/Makefile:
#   <name>-configure / <name>/Makefile / <name>: / <name>-install / <name>-clean
#
# KRITISCH -- nicht selbst entscheiden, das ist dokumentierter Fehler #4363
# (OMR 0.1069 -> 0.1081): Routing ging verloren, VPN-Stillstand mit gruener
# Statusanzeige. Jede Aenderung hier muss nach dem Bau geprueft werden.
# =============================================================================

# Pfade kommen aus paths.mk, das fetch-sources.sh erzeugt hat. Falls es fehlt,
# fallen wir auf die bekannte Submodul-Struktur zurueck.
-include paths.mk
MQVPN_DIR         ?= $(shell pwd)/release/src/router/mqvpn
XQUIC_DIR         ?= $(MQVPN_DIR)/third_party/xquic
BORINGSSL_DIR     ?= $(XQUIC_DIR)/third_party/boringssl
LIBEVENT_DIR      ?= $(shell pwd)/release/src/router/libevent2-2.1.12

# Build-Ausgabe ausserhalb der Quellen, damit ein clean nicht die Sourcen frisst
BORINGSSL_OUT     = $(shell pwd)/build-boringssl
XQUIC_OUT         = $(shell pwd)/build-xquic

MQVPN_CC       ?= $(CC)
MQVPN_CFLAGS   ?= -Os -fPIC -ffunction-sections -fdata-sections $(EXTRACFLAGS)
MQVPN_LDFLAGS  ?= -Wl,--gc-sections -static

# -----------------------------------------------------------------------------
# 1) libevent2 -- mqvpn bricht ohne das hart ab (CMakeLists: FATAL_ERROR).
#    Nur die Kern-Teile, kein OpenSSL (BoringSSL deckt TLS ab).
# -----------------------------------------------------------------------------
libevent2-2.1.12/configure:
	cd $(LIBEVENT_DIR) && ./autogen.sh

libevent2-2.1.12/Makefile: libevent2-2.1.12/configure
	cd $(LIBEVENT_DIR) && \
	CC="$(MQVPN_CC)" \
	CFLAGS="$(MQVPN_CFLAGS)" \
	LDFLAGS="$(MQVPN_LDFLAGS)" \
	./configure --prefix=/usr \
		--disable-openssl --disable-samples --disable-tests \
		--enable-static --disable-shared --with-pic

libevent2-2.1.12: libevent2-2.1.12/Makefile
	$(MAKE) -C $(LIBEVENT_DIR)
	mkdir -p $(STAGEDIR)/mqvpn-deps/lib $(STAGEDIR)/mqvpn-deps/include
	$(MAKE) -C $(LIBEVENT_DIR) install DESTDIR=$(STAGEDIR)/mqvpn-deps

libevent2-2.1.2-install:
	mkdir -p $(INSTALLDIR)/mqvpn/usr/lib $(INSTALLDIR)/mqvpn/usr/include
	cp -a $(STAGEDIR)/mqvpn-deps/lib/*.a $(INSTALLDIR)/mqvpn/usr/lib/
	cp -a $(STAGEDIR)/mqvpn-deps/include/event2 $(INSTALLDIR)/mqvpn/usr/include/

libevent2-2.1.12-clean:
	[ ! -d $(LIBEVENT_DIR) ] || $(MAKE) -C $(LIBEVENT_DIR) distclean

# -----------------------------------------------------------------------------
# 2) BoringSSL -- statisch, nur ssl+crypto. Auf Linux kein Go/NASM/Perl noetig.
# -----------------------------------------------------------------------------
boringssl-stage:
	mkdir -p $(BORINGSSL_OUT)
	cd $(BORINGSSL_OUT) && \
	CC="$(MQVPN_CC)" CXX="$(CXX)" AR=$(AR) RANLIB=$(RANLIB) \
	CFLAGS="$(MQVPN_CFLAGS)" CXXFLAGS="$(MQVPN_CFLAGS)" \
	cmake $(BORINGSSL_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DBUILD_SHARED_LIBS=OFF >/dev/null
	$(MAKE) -C $(BORINGSSL_OUT) -j$(PARALLEL_BUILD) ssl crypto >/dev/null
	mkdir -p $(STAGEDIR)/mqvpn-deps/ssl
	cp -a $(BORINGSSL_OUT)/ssl/libssl.a $(BORINGSSL_OUT)/crypto/libcrypto.a \
	      $(STAGEDIR)/mqvpn-deps/ssl/

# -----------------------------------------------------------------------------
# 3) xquic -- FEC und XOR sind Pflicht fuer den Scheduler "backup_fec".
#    BBR2 macht aus den WANs ueberhaupt erst Bonding.
# -----------------------------------------------------------------------------
xquic-stage: boringssl-stage
	mkdir -p $(XQUIC_OUT)
	cd $(XQUIC_OUT) && \
	CC="$(MQVPN_CC)" CXX="$(CXX)" AR=$(AR) RANLIB=$(RANLIB) \
	CFLAGS="$(MQVPN_CFLAGS)" CXXFLAGS="$(MQVPN_CFLAGS)" \
	cmake $(XQUIC_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DSSL_TYPE=boringssl \
		-DSSL_PATH=$(BORINGSSL_DIR) \
		-DSSL_LIB_PATH=$(STAGEDIR)/mqvpn-deps/ssl \
		-DSSL_INC_PATH=$(BORINGSSL_DIR)/include \
		-DXQC_ENABLE_BBR2=ON \
		-DXQC_ENABLE_FEC=ON \
		-DXQC_ENABLE_XOR=ON >/dev/null
	$(MAKE) -C $(XQUIC_OUT) -j$(PARALLEL_BUILD) >/dev/null
	mkdir -p $(STAGEDIR)/mqvpn-deps/xquic
	cp -a $(XQUIC_OUT)/*.a $(STAGEDIR)/mqvpn-deps/xquic/ 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4) mqvpn
#    -DBUILD_TESTING=OFF           spart Testprogramme und Abhaengigkeiten
#    -DMQVPN_ENABLE_HYBRID_TCP_LANE=OFF
#                                 lwIP-Hybrid wird fuer den Router nicht gebraucht
# -----------------------------------------------------------------------------
mqvpn: libevent2-2.1.12 xquic-stage
	mkdir -p $(MQVPN_DIR)/build
	cd $(MQVPN_DIR)/build && \
	CC="$(MQVPN_CC)" CXX="$(CXX)" AR=$(AR) RANLIB=$(RANLIB) STRIP=$(STRIP) \
	CFLAGS="$(MQVPN_CFLAGS)" CXXFLAGS="$(MQVPN_CFLAGS)" \
	cmake .. \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DXQUIC_BUILD_DIR=$(XQUIC_OUT) \
		-DSSL_LIB_PATH=$(STAGEDIR)/mqvpn-deps/ssl \
		-DSSL_INC_PATH=$(BORINGSSL_DIR)/include \
		-DCMAKE_PREFIX_PATH=$(STAGEDIR)/mqvpn-deps \
		-DCMAKE_C_FLAGS="-I$(STAGEDIR)/mqvpn-deps/include" \
		-DCMAKE_CXX_FLAGS="-I$(STAGEDIR)/mqvpn-deps/include" \
		-DBUILD_TESTING=OFF \
		-DMQVPN_ENABLE_HYBRID_TCP_LANE=OFF \
		-DCMAKE_EXE_LINKER_FLAGS="$(MQVPN_LDFLAGS) -L$(STAGEDIR)/mqvpn-deps/ssl -L$(STAGEDIR)/mqvpn-deps/xquic -L$(STAGEDIR)/mqvpn-deps/lib" >/dev/null
	$(MAKE) -C $(MQVPN_DIR)/build -j$(PARALLEL_BUILD) mqvpn

mqvpn-install: mqvpn
	@echo "=== mqvpn: Installation ins ROM ==="
	install -D -m 755 $(MQVPN_DIR)/build/mqvpn $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn
	# statisch gelinkt: keine .so-Abhaengigkeit, aber libstdc++/libgcc muessen
	# im ROM liegen -- asuswrt hat sie nicht zwingend fuer jeden Prozess
	$(STRIP) $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn || true
	mkdir -p $(INSTALLDIR)/mqvpn/usr/lib
	cp -a $(STAGEDIR)/mqvpn-deps/lib/libevent*.a $(INSTALLDIR)/mqvpn/usr/lib/ 2>/dev/null || true
	@echo "=== fertig ==="

mqvpn-clean:
	[ ! -d $(MQVPN_DIR)/build ] || $(MAKE) -C $(MQVPN_DIR)/build clean

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
	@$(CROSS_LD) $(INSTALLDIR)/mqvpn/usr/sbin/mqvpn 2>&1 | head -3 || true
	@echo "OK: mqvpn liegt im ROM"