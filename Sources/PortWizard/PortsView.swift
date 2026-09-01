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
        .task { await model.refresh(userInitiated: true) }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                // The same mark the menu bar shows, so the panel that opens
                // is recognisably the thing that was clicked.
                Image(nsImage: StatusIcon.shared)
                    .renderingMode(.template)
                    .foregroundStyle(.tint)
                Text("Port Wizard").font(.headline)
                Spacer()
                notificationMenu
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
                    Task { await model.refresh(userInitiated: true) }
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

    /// Notification settings: the master switch, the system-services escape
    /// hatch, and the list of hand-muted processes so a mute can be undone
    /// without hunting for the row that set it.
    private var notificationMenu: some View {
        Menu {
            Toggle("Notify about newly exposed ports", isOn: $model.notificationsEnabled)
            Toggle("Include macOS system services", isOn: $model.notifySystemServices)
                .disabled(!model.notificationsEnabled)

            if !model.mutedCommands.isEmpty {
                Divider()
                Section("Muted") {
                    ForEach(model.mutedCommands.sorted(), id: \.self) { command in
                        Button("Unmute \(command)") { model.toggleMute(command) }
                    }
                    if model.mutedCommands.count > 1 {
                        Button("Unmute All") { model.unmuteAll() }
                    }
                }
            }
        } label: {
            Image(systemName: model.notificationsEnabled ? "bell.fill" : "bell.slash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.notificationsEnabled ? Color.accentColor : .secondary)
        .help("Notification settings")
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
                        PortRowView(
                            row: row,
                            isMuted: model.isMuted(row.command),
                            onChange: { Task { await model.refresh() } },
                            setModal: { model.modalActive = $0 },
                            toggleMute: { model.toggleMute(row.command) }
                        )
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
            // The scan time used to live only in a tooltip, so a re-scan that
            // found the same ports — the common case — left the panel looking
            // untouched. It is on the face of the footer now.
            if model.isLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if let updated = model.lastUpdated {
                Text(model.hiddenSystemCount > 0
                     ? "\(model.rows.count) shown · \(model.hiddenSystemCount) system hidden · checked \(updated.formatted(.relative(presentation: .named)))"
                     : "\(model.rows.count) shown · \(model.listeningCount) listening · checked \(updated.formatted(.relative(presentation: .named)))")
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
    /// Whether this row's command is muted from exposed-port notifications.
    let isMuted: Bool
    var onChange: () -> Void
    var setModal: (Bool) -> Void
    var toggleMute: () -> Void
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
                    if isMuted {
                        Image(systemName: "bell.slash")
                            .help("Muted — this process won't raise port notifications")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)

            if hovering {
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
        .confirmationDialog(
            "Quit \(info.name) (PID \(row.pid))?",
            isPresented: $showKillConfirm, titleVisibility: .visible
        ) {
            Button("Quit (SIGTERM)") { kill(SIGTERM) }
            Button("Force Kill (SIGKILL)", role: .destructive) { kill(SIGKILL) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This releases port \(row.port). SIGTERM asks it to quit; "
                + "Force Kill terminates it immediately.")
        }
        // A confirmationDialog is a sheet that steals key focus; tell the app to
        // hold the transient popover open while it's presented.
        .onChange(of: showKillConfirm) { _, presented in
            setModal(presented)
        }
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
                Divider()
                Button(isMuted
                       ? "Unmute notifications for \(row.command)"
                       : "Mute notifications for \(row.command)") {
                    toggleMute()
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
