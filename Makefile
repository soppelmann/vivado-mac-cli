PREFIX ?= /usr/local
BIN := .build/release/vivado-mac

.PHONY: build install clean

build:
	swift build -c release
	codesign --force --sign - --entitlements vivado-mac.entitlements $(BIN)

# Deliberately not dependent on `build`: `sudo make install` would otherwise
# run swift build as root and leave root-owned files in .build, breaking the
# next unprivileged `make build`. Run `make build` first, then `sudo make install`.
install:
	@test -x $(BIN) || { echo "run 'make build' first"; exit 1; }
	install -d $(PREFIX)/bin
	install $(BIN) $(PREFIX)/bin/vivado-mac

clean:
	swift package clean
