# Two ways to build FreeBSD user programs for the board:
#   make          on the board itself (base-system cc)
#   make cross    on the Mac, with the toolchain the freebsd-ultrascale tree bootstrapped
PROG   ?= example
OBJ    ?= $(HOME)/Developer/ultrascale-board/obj
TMP    := $(shell find $(OBJ) -maxdepth 8 -type d -path '*arm64.aarch64/tmp' 2>/dev/null | head -1)
CFLAGS ?= -O2 -Wall -Wextra

$(PROG): $(PROG).c axi.h
	$(CC) $(CFLAGS) -o $@ $<

cross: $(PROG).c axi.h
	$(TMP)/usr/bin/cc --sysroot=$(TMP) -B$(TMP)/usr/bin -target aarch64-unknown-freebsd15.0 $(CFLAGS) -o $(PROG) $<
	file $(PROG)

clean:
	rm -f $(PROG)
