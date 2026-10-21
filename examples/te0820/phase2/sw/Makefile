# axiled — build either on the board (plain `make`, base-system cc) or cross from the Mac
# with the toolchain the freebsd-ultrascale tree bootstrapped (`make cross`).
OBJ    ?= $(HOME)/Developer/ultrascale-board/obj
TMP    := $(shell find $(OBJ) -maxdepth 8 -type d -path '*arm64.aarch64/tmp' 2>/dev/null | head -1)
CFLAGS ?= -O2 -Wall

axiled: axiled.c
	$(CC) $(CFLAGS) -o $@ $<

cross: axiled.c
	$(TMP)/usr/bin/cc --sysroot=$(TMP) -B$(TMP)/usr/bin -target aarch64-unknown-freebsd15.0 $(CFLAGS) -o axiled $<
	file axiled

clean:
	rm -f axiled
