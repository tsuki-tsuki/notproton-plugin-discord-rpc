CFLAGS := -std=c17 -O2 -Wall -Wextra -Werror
MACFLAGS := -arch arm64 -arch x86_64 -mmacosx-version-min=15.0
MINGW_CC ?= x86_64-w64-mingw32-gcc
MINGW_CC32 ?= i686-w64-mingw32-gcc
PYTHON ?= python3
RUNTIME := build/session-helper build/host build/notproton-discord.exe
ARCHIVE := dist/notproton-plugin-discord-rpc-session-helper.zip

.PHONY: all test wine-test release clean
all: $(RUNTIME)

build dist:
	mkdir -p $@

build/session-helper: session-helper | build
	cp -p $< $@

build/host: host.c protocol.h | build
	$(CC) $(CFLAGS) $(MACFLAGS) $< -o $@
	codesign -fs - --identifier org.notproton-plugin.discord-rpc.host $@

build/notproton-discord.exe: pipe.c protocol.h | build
	$(MINGW_CC) $(CFLAGS) -mwindows $< -lws2_32 -o $@

build/test-client.exe: tests/client.c protocol.h | build
	$(MINGW_CC) $(CFLAGS) $< -o $@

build/test-client32.exe: tests/client.c protocol.h | build
	$(MINGW_CC32) $(CFLAGS) $< -o $@

test: all
	$(PYTHON) tests/session_helper.py build/session-helper
	$(PYTHON) tests/host.py build/host

wine-test: all build/test-client.exe build/test-client32.exe
	$(PYTHON) tests/wine.py build

release: $(ARCHIVE)

$(ARCHIVE): $(RUNTIME) plugins/discord-rpc.conf LICENSE NOTICE README.md | dist
	rm -rf build/package
	mkdir -p build/package/plugins build/package/integrations/discord-rpc
	cp plugins/discord-rpc.conf build/package/plugins/
	cp $(RUNTIME) LICENSE NOTICE README.md build/package/integrations/discord-rpc/
	rm -f $@
	cd build/package && /usr/bin/zip -q -r ../../$@ plugins integrations

clean:
	rm -rf build dist
