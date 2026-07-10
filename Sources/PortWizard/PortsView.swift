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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if let updated = model.lastUpdated {
                Text("\(model.rows.count) shown · \(model.listeningCount) listening")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Updated \(updated.formatted(date: .omitted, time: .standard))")
            }
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A single port row with expandable action buttons.
private struct PortRowView: View {
    let row: PortRow
    var onChange: () -> Void
    @State private var hovering = false

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

            VStack(alignment: .leading, spacing: 2) {
                Text(row.command).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("PID \(row.pid)")
                    Text("·")
                    Text(row.hostSummary).lineLimit(1)
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
        .background(hovering ? Color.secondary.opacity(0.08) : .clear)
        .onHover { hovering = $0 }
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
            Button {
                ProcessActions.revealInFinder(pid: row.pid)
            } label: { Image(systemName: "magnifyingglass.circle") }
                .help("Reveal executable in Finder")

            Button {
                ProcessActions.signal(pid: row.pid, sig: SIGTERM)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onChange() }
            } label: { Image(systemName: "xmark.circle") }
                .help("Quit process (SIGTERM)")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}
