CFLAGS := -std=c17 -O2 -Wall -Wextra -Werror
MACFLAGS := -arch arm64 -arch x86_64 -mmacosx-version-min=15.0
MINGW_CC ?= x86_64-w64-mingw32-gcc
MINGW_CC32 ?= i686-w64-mingw32-gcc
PYTHON ?= python3
RUNTIME := build/host build/notproton-discord.exe
INJECTION_ARCHIVE := dist/notproton-plugin-discord-rpc.zip
HELPER_ARCHIVE := dist/notproton-plugin-discord-rpc-session-helper.zip

.PHONY: all test wine-test release clean
all: $(RUNTIME) build/discord-rpc.dylib build/session-helper

build dist:
	mkdir -p $@

build/session-helper: session-helper | build
	cp -p $< $@

build/discord-rpc.dylib: bootstrap.c | build
	$(CC) $(CFLAGS) $(MACFLAGS) -dynamiclib $< -o $@
	codesign -fs - --identifier org.notproton-plugin.discord-rpc $@

build/host: host.c activity.m activity.h protocol.h | build
	$(CC) $(CFLAGS) $(MACFLAGS) -fobjc-arc host.c activity.m -framework Foundation -o $@
	codesign -fs - --identifier org.notproton-plugin.discord-rpc.host $@

build/notproton-discord.exe: pipe.c protocol.h | build
	$(MINGW_CC) $(CFLAGS) -mwindows $< -lws2_32 -lntdll -o $@

build/test-client.exe: tests/client.c protocol.h | build
	$(MINGW_CC) $(CFLAGS) $< -lntdll -o $@

build/test-client32.exe: tests/client.c protocol.h | build
	$(MINGW_CC32) $(CFLAGS) $< -lntdll -o $@

test: all
	$(PYTHON) tests/bootstrap.py build/discord-rpc.dylib
	$(PYTHON) tests/session_helper.py build/session-helper
	$(PYTHON) tests/host.py build/host
	$(PYTHON) tests/activity.py build/host

wine-test: all build/test-client.exe build/test-client32.exe
	$(PYTHON) tests/wine.py build

release: $(INJECTION_ARCHIVE) $(HELPER_ARCHIVE)

$(INJECTION_ARCHIVE): plugins/discord-rpc-injection.conf build/discord-rpc.dylib
$(HELPER_ARCHIVE): plugins/discord-rpc.conf build/session-helper

$(INJECTION_ARCHIVE) $(HELPER_ARCHIVE): $(RUNTIME) LICENSE NOTICE README.md Makefile | dist
	rm -rf build/$(@F).package
	mkdir -p build/$(@F).package/plugins build/$(@F).package/integrations/discord-rpc
	cp $(filter plugins/%.conf,$^) build/$(@F).package/plugins/discord-rpc.conf
	cp $(filter build/%,$^) LICENSE NOTICE README.md build/$(@F).package/integrations/discord-rpc/
	rm -f $@
	cd build/$(@F).package && /usr/bin/zip -q -r ../../$@ plugins integrations

clean:
	rm -rf build dist
