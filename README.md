# Port Wizard

A tiny macOS **menu-bar app** that shows which ports are open on your Mac and
**which application owns each one** — so you can answer "what's running on 3000?"
without dropping into the terminal.

<p align="center">
  <em>🧙 Lives in your menu bar. One click shows every listening and connected port.</em>
</p>

## Features

- **Listening ports at a glance** — everything currently accepting connections,
  with the owning app, PID, and bind address.
- **Exposed vs. local** — a badge flags ports bound to all interfaces
  (🌐 reachable from the network) versus localhost-only (🔒).
- **Active connections** — switch to the *Connections* tab to see established
  sockets and their remote endpoints.
- **Search** — filter instantly by app name, port number, or address.
- **Quick actions** — reveal a process's executable in Finder, or quit it
  (SIGTERM) right from the row.
- **Menu-bar badge** — shows a live count of listening ports, refreshed in the
  background.
- **No dependencies, no privileges** — reads sockets via the system `lsof`.

## How it works

Port Wizard shells out to `/usr/sbin/lsof` with machine-readable field output
(`lsof -nP -i -F…`) and parses it into per-socket entries, then groups them by
process and port for display. Field output is used instead of the human table
because the table columns shift with address/state length and are fragile to
parse. See `Sources/PortWizard/PortScanner.swift`.

## Build & run

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16).

```bash
# Build a runnable .app bundle (ends up in .build/PortWizard.app)
./scripts/build-app.sh release
open .build/PortWizard.app     # look for the 🌐 icon in the menu bar
```

Or run headlessly to print the current listening ports to the terminal:

```bash
swift run PortWizard --scan
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

## License

MIT © 2026 Mohammad Al-Haddad
