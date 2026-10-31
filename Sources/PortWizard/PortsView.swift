import SwiftUI

/// The popover content: a searchable, filterable list of ports with per-row actions.
struct PortsView: View {
    @ObservedObject var model: PortsViewModel
    var onClose: () -> Void
    var onQuit: () -> Void

    /// The row whose kill confirmation is showing. Held here rather than on the
    /// row because a row can vanish mid-dialog — its process exiting, or the
    /// lazy list recycling it — and that must not take the dialog's state along.
    @State private var killTarget: PortRow?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let message = model.actionError { actionErrorBanner(message) }
            Divider()
            footer
        }
        .frame(width: 420, height: 520)
        .onExitCommand {
            if model.searchText.isEmpty { onClose() } else { model.searchText = "" }
        }
        .confirmationDialog(
            killTarget.map { "Quit \($0.displayName) (PID \($0.pid))?" } ?? "",
            isPresented: Binding(
                get: { killTarget != nil },
                set: { if !$0 { killTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: killTarget
        ) { row in
            Button("Quit (SIGTERM)") { model.terminate(row, signal: SIGTERM) }
            Button("Force Kill (SIGKILL)", role: .destructive) {
                model.terminate(row, signal: SIGKILL)
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("This releases port \(String(row.port)). SIGTERM asks it to quit; "
                + "Force Kill terminates it immediately.")
        }
        .onChange(of: killTarget) { _, target in
            model.modalActive = target != nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                // The same mark the menu bar shows, so the panel that opens
                // is recognisably the thing that was clicked.
                Image(nsImage: StatusIcon.shared)
                    .renderingMode(.template)
                    .foregroundStyle(.tint)
                Text("Port Wizard").font(.headline)
                Spacer()
                notificationMenu
                IconButton(
                    symbol: model.showSystem ? "eye" : "eye.slash",
                    label: model.showSystem
                        ? "Hide macOS system processes"
                        : "Show macOS system processes"
                ) { model.showSystem.toggle() }
                IconButton(symbol: "arrow.clockwise", label: "Refresh") {
                    Task { await model.refresh(userInitiated: true) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoading)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by app, port, or address", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: "Clear filter") {
                        model.searchText = ""
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
            if model.notificationsBlocked {
                Button("Allow Notifications in System Settings…") {
                    NotificationSettings.open()
                }
                Divider()
            }
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
            Image(systemName: model.notificationsEnabled && !model.notificationsBlocked
                  ? "bell.fill" : "bell.slash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.notificationsEnabled ? Color.accentColor : .secondary)
        .help(model.notificationsBlocked
              ? "Notifications are turned off for Port Wizard in System Settings"
              : "Notification settings")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = model.lastError {
            errorState(error)
        } else if model.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(PortSection.allCases) { section in
                        let rows = model.rows.filter { $0.section == section }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { row in
                                    PortRowView(
                                        row: row,
                                        isMuted: model.isMuted(row.command),
                                        toggleMute: { model.toggleMute(row.command) },
                                        requestKill: { killTarget = row }
                                    )
                                }
                            } header: {
                                sectionHeader(section, count: rows.count)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func sectionHeader(_ section: PortSection, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: section.symbol)
            Text(section.title)
            Spacer()
            Text(verbatim: String(count)).monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(section == .exposed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(error).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task { await model.refresh(userInitiated: true) }
            }
            .buttonStyle(.link)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Nothing to list has three different causes, and each has its own way out.
    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.lastUpdated == nil {
                ProgressView().controlSize(.large)
                Text("Scanning ports…").foregroundStyle(.secondary)
            } else if !model.searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("No ports match “\(model.searchText)”").foregroundStyle(.secondary)
                Button("Clear Filter") { model.searchText = "" }
                    .buttonStyle(.link)
            } else {
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("No ports here").foregroundStyle(.secondary)
                if model.hiddenSystemCount > 0 {
                    Button("Show \(model.hiddenSystemCount) system port(s)") {
                        model.showSystem = true
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", label: "Dismiss") { model.actionError = nil }
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 0)
            intervalMenu
            IconButton(symbol: "power", label: "Quit Port Wizard", action: onQuit)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The scan time stays on the face of the footer so a re-scan that found the
    /// same ports — the common case — doesn't leave the panel looking untouched.
    /// It re-renders on its own clock, or at a Manual cadence it would claim
    /// "now" indefinitely.
    @ViewBuilder
    private var status: some View {
        if model.isLoading {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Scanning…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let updated = model.lastUpdated {
            TimelineView(.periodic(from: updated, by: 1)) { context in
                Text(statusLine(updated: updated, now: context.date))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            .help("Updated \(updated.formatted(date: .omitted, time: .standard))")
        }
    }

    private func statusLine(updated: Date, now: Date) -> String {
        var parts = ["\(model.rows.count) shown"]
        if model.hiddenSystemCount > 0 { parts.append("\(model.hiddenSystemCount) system hidden") }
        parts.append(Self.age(of: updated, now: now))
        return parts.joined(separator: " · ")
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
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

/// A borderless symbol button, labelled for VoiceOver as well as on hover.
private struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).accessibilityLabel(label)
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}

/// A single port row. Actions overlay its trailing edge on hover rather than
/// sitting in the layout, so reaching for one doesn't make the text jump.
private struct PortRowView: View {
    let row: PortRow
    /// Whether this row's command is muted from exposed-port notifications.
    let isMuted: Bool
    var toggleMute: () -> Void
    var requestKill: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: String(row.port))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text(row.protocolLabel)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 48, alignment: .trailing)

            appIcon

            VStack(alignment: .leading, spacing: 0) {
                Text(row.displayName)
                    .fontWeight(.medium).lineLimit(1)
                    .help(row.executablePath ?? row.command)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(row.remotes.joined(separator: "\n"))
            }

            Spacer(minLength: 0)

            if isMuted {
                Image(systemName: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Muted — this process won't raise port notifications")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .background(
            hovering ? Color.secondary.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(alignment: .trailing) {
            if hovering { actions.padding(.trailing, 8) }
        }
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    /// Bundled apps show their own icon; bare executables get a terminal glyph.
    @ViewBuilder
    private var appIcon: some View {
        if let bundle = row.appBundlePath {
            Image(nsImage: AppIcon.image(forBundle: bundle))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    /// The second line: where the port is bound, or for a connection who is on
    /// the other end.
    private var detail: String {
        let pid = "PID \(row.pid)"
        guard let remote = row.remotes.first else { return "\(pid) · \(row.hostSummary)" }
        let more = row.remotes.count > 1 ? " +\(row.remotes.count - 1)" : ""
        return "\(pid) · → \(remote)\(more)"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let url = row.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: { Image(systemName: "safari").accessibilityLabel("Open in browser") }
                    .help("Open \(url.absoluteString) in browser")
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .primary)
                    .accessibilityLabel("More actions")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy, reveal, or mute…")

            Button(role: .destructive, action: requestKill) {
                Image(systemName: "xmark.circle").accessibilityLabel("Quit process")
            }
            .help("Quit or force-kill process")
            .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Shared by the hover menu and the row's right-click menu.
    @ViewBuilder
    private var menuItems: some View {
        Button("Copy port \(String(row.port))") { copy(String(row.port)) }
        Button("Copy \(row.address)") { copy(row.address) }
        if let url = row.url {
            Button("Copy URL") { copy(url.absoluteString) }
        }
        Button("Copy PID \(String(row.pid))") { copy(String(row.pid)) }
        if let path = row.executablePath {
            Button("Copy executable path") { copy(path) }
            Divider()
            Button("Reveal executable in Finder") {
                ProcessActions.revealInFinder(path: path)
            }
        }
        Divider()
        Button(isMuted
               ? "Unmute notifications for \(row.command)"
               : "Mute notifications for \(row.command)",
               action: toggleMute)
        Divider()
        Button("Quit or Force Kill…", role: .destructive, action: requestKill)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}
