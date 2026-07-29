# Contributing to fanknob

Bug reports, fixes and ideas are welcome. This covers building, testing and
releasing, plus the handful of things in the implementation that will catch you
out.

For what fanknob does and how to use it, see the [README](README.md).

## Layout

One SwiftPM package, no external dependencies. Three executables around a shared
core library:

```
Package.swift
Sources/
  FanknobCore/   shared engine: SMC access, fan/temp model, curves, daemon client
  fanknob/       the CLI and the TUI
  fanknobd/      the root daemon that performs privileged writes
  FanknobApp/    the SwiftUI menu-bar app
Tests/           unit tests for the pure logic in FanknobCore
app/Info.plist   app bundle metadata
packaging/       installer package definition + pre/postinstall scripts
scripts/         icon generation, and the UI, docs and installer-guard checks
com.fanknob.daemon.plist
```

Building requires Swift 6 and the macOS 15 SDK, provided by Xcode 16 or newer
(or its Command Line Tools). On an Xcode license error:
`sudo xcodebuild -license accept`.

## Build from source

```sh
git clone https://github.com/SadriG91/fanknob.git
cd fanknob
make app             # build everything + assemble build/Fanknob.app
sudo make install    # install CLI + daemon + app, and load the daemon
```

> Use ONE install method — the Homebrew cask or `make install`, not both. They
> write the same paths, so the second would leave a receipt claiming files it
> didn't put there and neither uninstaller would own the whole thing.
>
> They refuse each other symmetrically: `make install` checks for the package
> receipt, and `packaging/scripts/preinstall` checks for a source install (files
> present, no receipt). Users only ever see the cask — the raw `.pkg` is a
> release asset for the cask to download, not a documented install route.

All targets:

```sh
make                 # build everything (release)
make app             # assemble build/Fanknob.app
make run-app         # build + launch the menu-bar app
make shots           # re-render the documentation screenshots
make pkg             # unsigned installer .pkg, for local testing
make pkg-signed      # Developer ID signed .pkg (needs certs; CI does this)
make notarize        # notarize + staple the signed .pkg
make print-version   # the version, for scripts
make clean
sudo make install
sudo make uninstall
make test-preinstall # exercise the package/source-install guard
```

`make install` only *copies*, never builds — building as root would leave
root-owned files in `.build/` that break your later builds. Run `make app` first
as yourself.

## Testing

```sh
make test                                        # or: swift test
swift test --filter DaemonProtocolTests          # one suite
swift test --filter DaemonProtocolTests/plainSet # one test
python3 scripts/check-docs.py                    # local documentation links/assets
```

Unit tests cover the pure logic in `FanknobCore` — codecs, knob math, temperature
clustering, curves, config round-trips, the daemon protocol parser. They need no
hardware, root or daemon, so CI runs them whenever code, tests, packaging or
build configuration changes. They use
[Swift Testing](https://developer.apple.com/documentation/testing).

`make test-preinstall` exercises the installer guard against clean,
source-installed and package-upgrade fixtures. CI also checks that the guard is
present in the built package.

### UI acceptance tests

```sh
make ui-test
```

Two Python harnesses that drive the real app through the Accessibility API with
real CGEvent clicks. They need Fanknob.app running, the daemon installed, and
Accessibility permission for your terminal, so they can't run in CI. Run them if
you touch `FanModel` or the popover's control block — they cover the sticky
toggle and badge flicker, which unit tests can't see (see *SMC write lag*).

## Screenshots

The README and landing-page images are generated rather than captured by hand:

```sh
make shots
```

Re-run it after changing the popover and commit the result. A couple of PNGs
come out modified on every run regardless — the header's fan icon spins, so it
lands at a different angle each time. Nothing to chase.

## Releasing

The version lives in exactly one place, `Sources/FanknobCore/Version.swift`.
Bump it, commit, then push a matching `vX.Y.Z` tag:

```sh
git tag v1.4.2 && git push origin v1.4.2
```

The release workflow refuses a tag that disagrees with `Version.swift`. From
there it's automatic: build, sign with Developer ID, notarize, staple, publish
the `.pkg` and its checksum, then repoint the Homebrew cask in
`SadriG91/homebrew-tap`.

`CFBundleVersion` is the commit count rather than the marketing version, because
it has to increase monotonically and macOS reads `13` as newer than `1.4.0`. The
`CFBundleShortVersionString` in `app/Info.plist` is a placeholder — `make app`
stamps the real one in.

CI builds and tests on both `macos-15` (the deployment floor) and `macos-26` (the
SDK releases are built with; linking against an older one gets the app the legacy
compatibility appearance).

## How it works

### Fans

Per fan `i` the SMC exposes `FNum` (count), `FiAc` (actual RPM), `FiMn`/`FiMx`
(min/max), `FiTg` (target RPM) and `FiMd` (mode: 0 auto, 1 manual). To force a
speed, write `1` to `FiMd` then the RPM to `FiTg`; to release, write `0`. The
0–100 knob is just a position in the `FiMn`→`FiMx` range.

### Temperature

Apple Silicon has no single documented "CPU temp" key, so fanknob scans every
`T…` sensor of type `flt` in a plausible range and averages the CPU (`Tp*`) and
GPU (`Tg*`) clusters — about 54 CPU probes on an M2 Pro. The keys are enumerated
once and re-read directly afterwards, so a live view doesn't rescan all ~1500 SMC
keys per frame.

### The 80-byte struct

`SMCKeyData_t` is exactly 80 bytes. Swift reuses a nested struct's trailing
padding for the next field where C does not, silently packing it to 76 and making
every `IOConnectCallStructMethod` fail with `kIOReturnBadArgument`. Hence the
explicit padding in `SMCKeyInfoData` — don't tidy it away, and re-check the size
if you add a field.

### SMC write lag

After a mode write the SMC keeps reporting the **old** `FiMd` for tens of
milliseconds, and it can't tell a curve from a fixed speed — both read as
"managed". Two consequences, both load-bearing:

- The mode of record is the **daemon's** state whenever it's reachable; the SMC
  is only the fallback. Only the daemon knows a curve is driving.
- `FanModel` runs a mode intent guard and an in-flight write counter, so a poll
  taken before a user action can't publish after it and yank the UI back. Badges
  come from the app's mode, never from `Fan.managed`.

### Daemon security

The root daemon accepts only `set`, `setfan`, `curve`, `preset`, `watchdog`,
`auto` and `state`, each validated and range-checked by one pure function —
`parseDaemonCommand` in `Daemon.swift` — before anything reaches the SMC. Any
local user can connect, but can't drive it to do anything except move fans.
That is an explicit trust decision, not per-user authorization: fan control is
system-wide, and any local account can change the active mode, safety limit and
persisted settings. Keep the shared-Mac warning in the README and landing page
in sync with this behavior.

**Adding a command touches four places:** the `DaemonCommand` enum and its
parser, `Controller.handle`, the `FanController` facade, and the callers. Keep
the validation in the parser so it stays testable without hardware.

It's also a system-wide singleton (flock on `/var/run/fanknobd.lock`) so two
installs can't fight over the socket, and it hands the fans back on
SIGTERM/SIGINT — the SMC holds `FiMd = 1` until something writes 0, so a daemon
that simply exited would leave them pinned with nothing left to move them.

## Packaging

Three details in `packaging/` are load-bearing and easy to undo by accident:

- **`component.plist` sets `BundleIsRelocatable=false`.** pkgbuild treats `.app`
  bundles as relocatable by default, so Installer asks LaunchServices where
  `com.fanknob.app` already lives and installs *there* — leaving `/Applications`
  empty on any machine that has ever opened a copy from `~/Downloads`. Shipped
  that way in 1.4.0; CI now greps the built package for `relocatable="false"`.
- **`scripts/preinstall` keeps install ownership unambiguous.** It refuses to
  put the package on top of a source-built copy with no package receipt; the
  Makefile checks the opposite direction. `make test-preinstall` covers clean
  installs, conflicts and package upgrades.
- **`scripts/postinstall` is why this ships as a `.pkg` at all.** Installer is
  already root, so it loads the daemon and waits for the socket before declaring
  success — fan control works the moment the install finishes.

If `codesign` fails with *"unable to build chain to self-signed root"* and
`security find-identity` shows 0 valid identities, the Developer ID G2
intermediate is missing from the keychain — the key itself is fine. The release
workflow imports it explicitly from Apple.

## Working with Claude Code

[CLAUDE.md](CLAUDE.md) holds the same ground rules in the form Claude Code reads
at the start of a session. If you change something structural — the daemon
protocol, the threading model, the release flow — update both.
