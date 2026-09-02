# Port Wizard

A tiny macOS **menu-bar app** that shows which ports are open on your Mac and
**which application owns each one** — so you can answer "what's running on 3000?"
without dropping into the terminal.

<p align="center">
  <em>🧙 Lives in your menu bar. One click shows every listening and connected port.</em>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-orange?logo=swift">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

## Features

- **User apps only, by default** — Apple/system daemons (`ControlCenter`,
  `rapportd`, `mDNSResponder`, …) are hidden so you see what *you* started:
  nginx, node/Express, Postgres, Docker, and friends. Toggle the 👁 button (or
  pass `--all` on the CLI) to reveal system processes.
- **Listening ports at a glance** — everything currently accepting connections,
  with the owning app, PID, and bind address.
- **Exposed vs. local** — a badge flags ports bound to all interfaces
  (🌐 reachable from the network) versus localhost-only (🔒).
- **Real app names & icons** — GUI apps show their Launch Services name and icon
  (Visual Studio Code, Docker, Chrome); CLI tools and daemons fall back to the
  process name with a terminal glyph.
- **Active connections** — switch to the *Connections* tab to see established
  sockets and their remote endpoints.
- **Search** — filter instantly by app name, port number, or address.
- **Quick actions** on hover:
  - **Open in browser** — one click to `http://localhost:PORT` for TCP listeners.
  - **Copy…** — port, `host:port`, full URL, PID, or executable path.
  - **Reveal** the executable in Finder.
  - **Quit / Force-Kill** — with a confirmation offering SIGTERM or SIGKILL.
- **Configurable refresh** — pick a background re-scan cadence (Manual / 2s / 5s
  / 10s / 30s / 1m) from the footer; the choice is remembered.
- **Exposed-port notifications** — optionally get notified the moment a process
  starts listening on a network-reachable port (a dev server coming up, or an
  unexpected port opening — a handy security signal). Toggle the 🔔 in the header.
- **Mute the noisy ones** — a process that rebinds constantly can be muted from
  its own row, and unmuted from the mute list in either the 🔔 menu or the
  right-click menu. Apple's Continuity daemons are excluded by default for
  exactly this reason; **Include macOS System Services** opts back in.
- **Right-click menu** — the notification switches, the mute list, and Quit,
  without opening the panel at all.
- **Menu-bar badge** — shows a live count of listening ports, refreshed in the
  background.
- **No dependencies, no privileges** — reads sockets via the system `lsof`.

## How it works

Port Wizard shells out to `/usr/sbin/lsof` with machine-readable field output
(`lsof -nP -i -F…`) and parses it into per-socket entries, then groups them by
process and port for display. Field output is used instead of the human table
because the table columns shift with address/state length and are fragile to
parse. See `Sources/PortWizard/PortScanner.swift`.

## Install

### From a release DMG

Download the latest `PortWizard.dmg`, open it, and drag **Port Wizard** into
**Applications**. Local builds are ad-hoc signed rather than notarized, so the
first launch needs a right-click → **Open** to get past Gatekeeper.

To build the DMG yourself:

```bash
./scripts/build-dmg.sh        # → .build/PortWizard.dmg
```

## Build & run

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16).

```bash
# Build a runnable .app bundle (ends up in .build/PortWizard.app)
./scripts/build-app.sh release
open .build/PortWizard.app     # look for the wand-and-globe icon in the menu bar
```

Or run headlessly to print the current listening ports to the terminal:

```bash
swift run PortWizard --scan        # user apps only
swift run PortWizard --scan --all  # include macOS system processes
```

## Development

```bash
swift build      # compile
swift test       # run the lsof parser unit tests
```

The parser is pure and fully unit-tested against captured `lsof -F` fixtures
(`Tests/PortWizardTests/ParserTests.swift`), so the tricky address-parsing logic
(IPv4, bracketed IPv6, `host:port->remote`, wildcard UDP) is verified without
needing live sockets.

### The icon

The mark is a `network` glyph with a wand badged into its lower-right corner,
composed from two SF Symbols because there is no combined one. It is drawn
twice: `Sources/PortWizard/StatusIcon.swift` builds the flat template image the
menu bar tints, and `scripts/make-appicon.swift` builds the colour version and
writes `Resources/AppIcon.icns`. The geometry both share lives in
`Sources/PortWizard/SymbolDrawing.swift`.

The `.icns` is committed, so a normal build needs neither Xcode nor this script.
Re-run it only when changing the mark:

```bash
./scripts/make-appicon.sh
```

## License

MIT © 2026 Mohammad Al-Haddad
