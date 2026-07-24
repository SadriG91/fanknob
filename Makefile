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

.PHONY: all app run-app clean install uninstall

all:
	$(SWIFT_BUILD)

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

install: all app
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make install"; exit 1; }
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
