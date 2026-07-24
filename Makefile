# fanknob — knob-style fan control for Apple Silicon
#
#   make                 build everything (release)
#   make app             assemble Fanknob.app (menu-bar app)
#   make run-app         build + assemble + launch the app
#   sudo make install    install CLI + daemon + app, load the daemon
#   sudo make uninstall
#
# Building the SwiftUI app needs the macOS SDK from Xcode or the Command Line
# Tools. If you hit an Xcode license error, run: sudo xcodebuild -license accept
SWIFT_BUILD = swift build -c release
BIN = .build/release
PREFIX = /usr/local/bin
PLISTDIR = /Library/LaunchDaemons
PLIST = com.fanknob.daemon.plist
APPDIR = /Applications
APP = Fanknob.app

.PHONY: all app run-app test ui-test clean install uninstall

all:
	$(SWIFT_BUILD)

# Unit tests (pure logic: codecs, knob math, temp clustering, daemon protocol).
test:
	swift test

# UI acceptance test for the menu-bar app's toggle (real synthetic clicks).
# Needs: app running, daemon installed, terminal with Accessibility permission.
ui-test:
	swiftc -O scripts/click.swift -o /tmp/fanknob-click
	python3 scripts/toggle-acceptance.py

# Assemble a double-clickable menu-bar .app around the built binary.
app: all
	rm -rf build/$(APP)
	mkdir -p build/$(APP)/Contents/MacOS
	cp app/Info.plist build/$(APP)/Contents/Info.plist
	cp $(BIN)/FanknobApp build/$(APP)/Contents/MacOS/FanknobApp
	@echo "Built build/$(APP)"

run-app: app
	@echo "Launching Fanknob…"
	open build/$(APP)

clean:
	swift package clean
	rm -rf build

# install only COPIES artifacts — it never builds. Building as root would
# leave root-owned files in .build/ and build/ that break later user builds.
install:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make install"; exit 1; }
	@[ -x $(BIN)/fanknob ] && [ -x $(BIN)/fanknobd ] && [ -d build/$(APP) ] || \
		{ echo "artifacts missing — run 'make app' first (as your normal user), then sudo make install"; exit 1; }
	install -m 755 $(BIN)/fanknob  $(PREFIX)/fanknob
	install -m 755 $(BIN)/fanknobd $(PREFIX)/fanknobd
	install -m 644 $(PLIST) $(PLISTDIR)/$(PLIST)
	rm -rf $(APPDIR)/$(APP)
	cp -R build/$(APP) $(APPDIR)/$(APP)
	-launchctl bootout system $(PLISTDIR)/$(PLIST) 2>/dev/null
	launchctl bootstrap system $(PLISTDIR)/$(PLIST)
	@echo "Installed. CLI: fanknob   ·   App: open -a Fanknob   ·   Daemon loaded."

uninstall:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make uninstall"; exit 1; }
	-launchctl bootout system $(PLISTDIR)/$(PLIST) 2>/dev/null
	rm -f  $(PLISTDIR)/$(PLIST) $(PREFIX)/fanknob $(PREFIX)/fanknobd /var/run/fanknobd.sock
	rm -rf $(APPDIR)/$(APP)
	@echo "Uninstalled. (Run 'fanknob auto' first if fans were left in manual.)"
