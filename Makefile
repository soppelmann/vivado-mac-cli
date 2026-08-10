PREFIX ?= /usr/local
BIN := .build/release/vivado-mac

.PHONY: build install clean

build:
	swift build -c release
	codesign --force --sign - --entitlements vivado-mac.entitlements $(BIN)

install: build
	install -d $(PREFIX)/bin
	install $(BIN) $(PREFIX)/bin/vivado-mac

clean:
	swift package clean
