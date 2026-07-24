# fanknob — knob-style fan control for Apple Silicon
#
#   make              build both binaries
#   make clean        remove built binaries
#   sudo make install install to /usr/local/bin + load the root daemon
#   sudo make uninstall
#
# After `sudo make install`, plain `fanknob set 40` / `fanknob auto` work with
# no sudo: the client talks to the root daemon over a socket.

CORE   = SMC.swift
CLIENT = fanknob
DAEMON = fanknobd
PLIST  = com.fanknob.daemon.plist
PREFIX = /usr/local/bin
PLISTDIR = /Library/LaunchDaemons

.PHONY: all clean install uninstall

all: $(CLIENT) $(DAEMON)

$(CLIENT): $(CORE) TUI.swift fanknob.swift
	swiftc -O -parse-as-library $(CORE) TUI.swift fanknob.swift -framework IOKit -o $(CLIENT)

$(DAEMON): $(CORE) fanknobd.swift
	swiftc -O -parse-as-library $(CORE) fanknobd.swift -framework IOKit -o $(DAEMON)

clean:
	rm -f $(CLIENT) $(DAEMON)

install: all
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make install"; exit 1; }
	install -m 755 $(CLIENT) $(PREFIX)/$(CLIENT)
	install -m 755 $(DAEMON) $(PREFIX)/$(DAEMON)
	install -m 644 $(PLIST) $(PLISTDIR)/$(PLIST)
	# Reload the daemon (ignore errors if not previously loaded).
	-launchctl bootout system $(PLISTDIR)/$(PLIST) 2>/dev/null
	launchctl bootstrap system $(PLISTDIR)/$(PLIST)
	@echo "Installed. Try:  fanknob status   then   fanknob set 40   (no sudo)"

uninstall:
	@[ "$$(id -u)" = "0" ] || { echo "run: sudo make uninstall"; exit 1; }
	-launchctl bootout system $(PLISTDIR)/$(PLIST) 2>/dev/null
	rm -f $(PLISTDIR)/$(PLIST) $(PREFIX)/$(CLIENT) $(PREFIX)/$(DAEMON) /var/run/fanknobd.sock
	@echo "Uninstalled. (Fans left in whatever mode they were in — run 'fanknob auto' first if manual.)"
