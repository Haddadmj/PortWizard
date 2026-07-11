import SwiftUI

/// The popover content: a searchable, filterable list of ports with per-row actions.
struct PortsView: View {
    @ObservedObject var model: PortsViewModel
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 520)
        .task { await model.refresh() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.tint)
                Text("Port Wizard").font(.headline)
                Spacer()
                Button {
                    model.notificationsEnabled.toggle()
                } label: {
                    Image(systemName: model.notificationsEnabled ? "bell.fill" : "bell.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.notificationsEnabled ? Color.accentColor : .secondary)
                .help(model.notificationsEnabled
                      ? "Stop notifying about newly exposed ports"
                      : "Notify when a process starts listening on a network-exposed port")
                Button {
                    model.showSystem.toggle()
                } label: {
                    Image(systemName: model.showSystem ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(model.showSystem
                      ? "Hide macOS system processes"
                      : "Show macOS system processes")
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(model.isLoading)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by app, port, or address", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Picker("", selection: $model.filter) {
                ForEach(PortFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.lastError {
            errorState(error)
        } else if model.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        PortRowView(row: row) {
                            Task { await model.refresh() }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(error).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isLoading ? "hourglass" : "checkmark.seal")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(model.isLoading ? "Scanning ports…" : "No matching ports")
                .foregroundStyle(.secondary)
            if !model.isLoading, model.hiddenSystemCount > 0 {
                Button("Show \(model.hiddenSystemCount) system port(s)") {
                    model.showSystem = true
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if let updated = model.lastUpdated {
                Text(model.hiddenSystemCount > 0
                     ? "\(model.rows.count) shown · \(model.hiddenSystemCount) system hidden"
                     : "\(model.rows.count) shown · \(model.listeningCount) listening")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Updated \(updated.formatted(date: .omitted, time: .standard))")
            }
            Spacer()
            intervalMenu
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Auto-refresh cadence picker, living in the footer.
    private var intervalMenu: some View {
        Menu {
            Picker("Refresh every", selection: $model.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.menuLabel).tag(interval)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.refreshInterval.shortLabel, systemImage: "timer")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How often to re-scan ports")
    }
}

/// A single port row with expandable action buttons.
private struct PortRowView: View {
    let row: PortRow
    var onChange: () -> Void
    @State private var hovering = false
    @State private var copied = false
    @State private var showKillConfirm = false

    private var info: AppInfo.Info { AppInfo.lookup(pid: row.pid, fallbackCommand: row.command) }

    var body: some View {
        HStack(spacing: 10) {
            // Port badge.
            VStack(spacing: 2) {
                Text("\(row.port)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text(row.protocolLabel)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(width: 56)

            // App icon.
            if let icon = info.icon {
                Image(nsImage: icon)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("PID \(row.pid)")
                    Text("·")
                    Text(row.hostSummary).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)

            if showKillConfirm {
                killConfirmBar
            } else if hovering {
                actions
            } else {
                statusBadge
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background((hovering || showKillConfirm) ? Color.secondary.opacity(0.08) : .clear)
        .onHover { hovering = $0 }
    }

    /// Inline kill confirmation. Kept inside the popover (rather than a
    /// confirmationDialog) because a sheet-style dialog steals key focus and
    /// dismisses the transient menu-bar popover.
    private var killConfirmBar: some View {
        HStack(spacing: 6) {
            Text("Release \(row.port)?")
                .font(.caption).foregroundStyle(.secondary)
            Button("Quit") { kill(SIGTERM); showKillConfirm = false }
                .help("Send SIGTERM (graceful)")
            Button("Force") { kill(SIGKILL); showKillConfirm = false }
                .foregroundStyle(.red)
                .help("Send SIGKILL (immediate)")
            Button { showKillConfirm = false } label: { Image(systemName: "xmark") }
                .foregroundStyle(.secondary)
                .help("Cancel")
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private var statusBadge: some View {
        Group {
            if row.isListening {
                Label(row.isPublicBind ? "Exposed" : "Local",
                      systemImage: row.isPublicBind ? "globe" : "lock")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(row.isPublicBind ? .orange : .green)
                    .help(row.isPublicBind
                          ? "Listening on all interfaces (reachable from the network)"
                          : "Listening on localhost only")
            } else {
                Text("×\(row.connectionCount)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("\(row.connectionCount) active connection(s)")
            }
        }
        .frame(width: 28)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if row.isBrowsable {
                Button {
                    if let url = URL(string: "http://\(row.reachableHost):\(row.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: { Image(systemName: "safari") }
                    .help("Open http://\(row.reachableHost):\(row.port) in browser")
            }

            Menu {
                Button("Copy port \(row.port)") { copy("\(row.port)") }
                Button("Copy \(row.reachableHost):\(row.port)") {
                    copy("\(row.reachableHost):\(row.port)")
                }
                Button("Copy URL") { copy("http://\(row.reachableHost):\(row.port)") }
                Button("Copy PID \(row.pid)") { copy("\(row.pid)") }
                if let path = row.executablePath {
                    Button("Copy executable path") { copy(path) }
                }
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .primary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy…")

            Button {
                ProcessActions.revealInFinder(pid: row.pid)
            } label: { Image(systemName: "magnifyingglass.circle") }
                .help("Reveal executable in Finder")

            Button(role: .destructive) {
                showKillConfirm = true
            } label: { Image(systemName: "xmark.circle") }
                .help("Quit or force-kill process")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }

    private func kill(_ sig: Int32) {
        ProcessActions.signal(pid: row.pid, sig: sig)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onChange() }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}
