# fanknob — knob-style fan control for Apple Silicon
#
#   make                 build everything (release)
#   make app             assemble Fanknob.app (menu-bar app)
#   make run-app         build + assemble + launch the app
#   make shots           re-render the documentation screenshots
#   make pkg             build an unsigned installer .pkg (local testing)
#   make pkg-signed      build a Developer ID signed .pkg
#   make notarize        notarize + staple the signed .pkg
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

# The version lives in exactly one place — Sources/FanknobCore/Version.swift —
# and everything else reads it from there. CFBundleVersion is the commit count
# instead: it has to increase monotonically, and the marketing version doesn't
# (macOS compares "13" as newer than "1.4.0").
VERSION = $(shell sed -n 's/.*fanknobVersion = "\(.*\)".*/\1/p' Sources/FanknobCore/Version.swift)
BUILD_NUMBER = $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

PKG_ID = com.fanknob.pkg
PKGROOT = build/pkgroot
PKG = build/Fanknob-$(VERSION).pkg

# Overridden in CI with the full "Developer ID ...: Name (TEAMID)" strings.
SIGN_APP ?= Developer ID Application
SIGN_PKG ?= Developer ID Installer
NOTARY_PROFILE ?= fanknob-notary

.PHONY: all app run-app stage pkg pkg-signed notarize print-version test ui-test shots clean install uninstall

all:
	$(SWIFT_BUILD)

# Read by CI and by anything else that needs the version without parsing Swift.
print-version:
	@echo $(VERSION)

# Unit tests (pure logic: codecs, knob math, temp clustering, daemon protocol).
test:
	swift test

# UI acceptance test for the menu-bar app's toggle (real synthetic clicks).
# Needs: app running, daemon installed, terminal with Accessibility permission.
ui-test:
	swiftc -O scripts/click.swift -o /tmp/fanknob-click
	python3 scripts/toggle-acceptance.py
	python3 scripts/badge-acceptance.py

# Regenerate the README/landing-page screenshots from the real views, in both
# light and dark. Deliberately a debug build: the renderer is behind #if DEBUG
# so it never ships. See Sources/FanknobApp/Shots.swift.
shots:
	swift build
	./.build/debug/FanknobApp --render-shots docs/screenshots

# Assemble a double-clickable menu-bar .app around the built binary.
# (assets/AppIcon.icns is generated from assets/fanknob_logo.png by
#  scripts/make-icon.swift + iconutil; regenerate only when the logo changes.)
app: all
	rm -rf build/$(APP)
	mkdir -p build/$(APP)/Contents/MacOS build/$(APP)/Contents/Resources
	cp app/Info.plist build/$(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" build/$(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" build/$(APP)/Contents/Info.plist
	cp assets/AppIcon.icns build/$(APP)/Contents/Resources/AppIcon.icns
	cp $(BIN)/FanknobApp build/$(APP)/Contents/MacOS/FanknobApp
	@# assets/AppIcon.icns carries a com.apple.quarantine xattr in the working
	@# tree and cp propagates it into the bundle, which both `make install` and
	@# the .pkg would then ship to /Applications. Clear it here.
	@# (com.apple.provenance is restricted and survives this — kernel-managed,
	@# and macOS maintains it on its own terms.)
	xattr -cr build/$(APP)
	@echo "Built build/$(APP)  —  $(VERSION) (build $(BUILD_NUMBER))"

run-app: app
	@echo "Launching Fanknob…"
	open build/$(APP)

# --- Installer package ------------------------------------------------------
#
# The payload is staged into build/pkgroot with exactly the layout `sudo make
# install` produces, so the two install paths stay interchangeable rather than
# fighting over the same LaunchDaemon.
#
#   make pkg          unsigned, for local testing (installer(8) accepts it)
#   make pkg-signed   Developer ID signed; `make notarize` then staples it
#
# pkgbuild/productbuild are invoked identically either way — only the payload
# differs (signed binaries or not), so the recipe lives in one place.
define build_product
	pkgbuild --root $(PKGROOT) --component-plist packaging/component.plist \
	         --scripts packaging/scripts \
	         --identifier $(PKG_ID) --version $(VERSION) \
	         --ownership recommended --install-location / build/component.pkg
	productbuild --distribution packaging/distribution.xml \
	             --package-path build $(1)
endef

stage: app
	rm -rf $(PKGROOT)
	mkdir -p $(PKGROOT)$(PREFIX) $(PKGROOT)$(PLISTDIR) $(PKGROOT)$(APPDIR)
	install -m 755 $(BIN)/fanknob  $(PKGROOT)$(PREFIX)/fanknob
	install -m 755 $(BIN)/fanknobd $(PKGROOT)$(PREFIX)/fanknobd
	install -m 644 $(PLIST) $(PKGROOT)$(PLISTDIR)/$(PLIST)
	cp -R build/$(APP) $(PKGROOT)$(APPDIR)/$(APP)
	@# Clear inherited quarantine before the package is cut: extended attributes
	@# ride into the payload as AppleDouble (._foo) entries and get restored on
	@# the target machine. Also runs before codesign touches the staged copies.
	xattr -cr $(PKGROOT)

pkg: stage
	$(call build_product,$(PKG))
	@echo "Built $(PKG) — UNSIGNED (local testing only)"

# Hardened runtime (--options runtime) is what notarization requires; it costs
# us nothing, since IOKit/SMC access needs no entitlement.
pkg-signed: stage
	codesign --force --options runtime --timestamp --sign "$(SIGN_APP)" \
	    $(PKGROOT)$(PREFIX)/fanknob $(PKGROOT)$(PREFIX)/fanknobd
	codesign --force --options runtime --timestamp --sign "$(SIGN_APP)" \
	    $(PKGROOT)$(APPDIR)/$(APP)
	codesign --verify --strict --verbose=2 $(PKGROOT)$(APPDIR)/$(APP)
	$(call build_product,build/unsigned.pkg)
	productsign --sign "$(SIGN_PKG)" build/unsigned.pkg $(PKG)
	rm -f build/unsigned.pkg
	@echo "Built $(PKG) — signed, not yet notarized"

# Local notarization. Store credentials once with:
#   xcrun notarytool store-credentials fanknob-notary --key <p8> \
#         --key-id <id> --issuer <uuid>
# (CI passes --key/--key-id/--issuer directly instead.)
notarize:
	xcrun notarytool submit $(PKG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(PKG)
	spctl -a -vvv -t install $(PKG)

clean:
	swift package clean
	rm -rf build

# install only COPIES artifacts — it never builds. Building as root would
# leave root-owned files in .build/ and build/ that break later user builds.
install:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make install"; exit 1; }
	@! pkgutil --pkg-info $(PKG_ID) >/dev/null 2>&1 || { \
		echo "fanknob is already installed from the .pkg (or the Homebrew cask)."; \
		echo "Installing over it would leave a stale receipt claiming files this target owns."; \
		echo "Remove it first:  brew uninstall --cask fanknob   (or: sudo make uninstall)"; exit 1; }
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
	rm -f  $(PLISTDIR)/$(PLIST) $(PREFIX)/fanknob $(PREFIX)/fanknobd /var/run/fanknobd.sock /var/run/fanknobd.lock
	rm -rf $(APPDIR)/$(APP)
	-pkgutil --forget $(PKG_ID) 2>/dev/null
	@echo "Uninstalled. (bootout sends SIGTERM, so the daemon handed the fans back on its way out.)"
