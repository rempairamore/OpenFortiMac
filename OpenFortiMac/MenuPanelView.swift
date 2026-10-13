import SwiftUI

/// Content of the popover shown when clicking the menu bar icon.
struct MenuPanelView: View {
    @ObservedObject var model: PanelViewModel
    @ObservedObject var vpn: VPNManager

    /// Rows shown before the server list starts scrolling
    private let maxVisibleServers = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusCard(vpn: vpn, onDisconnect: model.disconnect)
                .padding(12)

            if let banner = setupBanner {
                banner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            Divider()

            serverSection
                .padding(.vertical, 8)

            Divider()

            footer
        }
        .frame(width: 320)
    }

    // MARK: - Setup banner

    private var setupBanner: SetupBanner? {
        switch model.sudoersStatus {
        case .missing:
            return SetupBanner(
                title: "Administrator permission not set up",
                detail: "openfortivpn needs it to start the tunnel.",
                action: "Set up"
            ) { model.openSettings(.permission, nil) }
        case .outdated:
            return SetupBanner(
                title: "Permission points to another openfortivpn",
                detail: "Update the rule after moving openfortivpn.",
                action: "Update"
            ) { model.openSettings(.permission, nil) }
        case .binaryNotFound:
            return SetupBanner(
                title: "openfortivpn not found",
                detail: "Install it with brew install openfortivpn.",
                action: "Settings"
            ) { model.openSettings(.general, nil) }
        default:
            return nil
        }
    }

    // MARK: - Servers

    @ViewBuilder
    private var serverSection: some View {
        if model.servers.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Add your first server")
                    .font(.callout)
                Button("Add server") { model.openSettings(.servers, .add) }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Servers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)

                if model.servers.count > maxVisibleServers {
                    ScrollView {
                        serverList
                    }
                    .frame(height: CGFloat(maxVisibleServers) * 44)
                } else {
                    serverList
                }
            }
        }
    }

    private var serverList: some View {
        VStack(spacing: 2) {
            ForEach(model.servers) { server in
                PanelServerRow(
                    server: server,
                    isActive: vpn.currentServer?.id == server.id,
                    canConnect: vpn.state == .disconnected,
                    hasPassword: !model.serversWithoutPassword.contains(server.id)
                ) {
                    model.connect(server)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(symbol: "plus", help: "Add server") {
                model.openSettings(.servers, .add)
            }
            FooterButton(symbol: "gearshape", help: "Settings") {
                model.openSettings(nil, nil)
            }
            .keyboardShortcut(",", modifiers: .command)
            FooterButton(symbol: "doc.text", help: "Log") {
                model.openSettings(.log, nil)
            }

            Spacer()

            FooterButton(symbol: "power", help: "Quit OpenFortiMac") {
                model.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Status Card

private struct StatusCard: View {
    @ObservedObject var vpn: VPNManager
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isConnected ? "lock.fill" : "lock.open")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(tint)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    subtitle
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                switch vpn.state {
                case .connected:
                    Button("Disconnect", action: onDisconnect)
                        .keyboardShortcut("d", modifiers: .command)
                case .connecting:
                    Button("Cancel", action: onDisconnect)
                default:
                    EmptyView()
                }
            }

            if isConnected, let server = vpn.currentServer {
                HStack(spacing: 12) {
                    if let ip = vpn.assignedIP {
                        Label(ip, systemImage: "network")
                    }
                    Label("\(server.host):\(server.port)", systemImage: "globe")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = vpn.state { return true }
        return false
    }

    private var isBusy: Bool {
        vpn.state == .connecting || vpn.state == .disconnecting
    }

    private var tint: Color {
        switch vpn.state {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private var title: String {
        switch vpn.state {
        case .disconnected: return "Not connected"
        case .connected(let serverName): return serverName
        case .connecting, .disconnecting: return vpn.currentServer?.name ?? "VPN"
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch vpn.state {
        case .disconnected:
            Text("Choose a server to connect")
        case .connecting:
            Text("Connecting…")
        case .disconnecting:
            Text("Disconnecting…")
        case .connected:
            if let since = vpn.connectedSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Connected · \(Self.format(context.date.timeIntervalSince(since)))")
                        .monospacedDigit()
                }
            } else {
                Text("Connected")
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Setup Banner

private struct SetupBanner: View {
    let title: String
    let detail: String
    let action: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Button(action, action: onAction)
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

// MARK: - Server Row

private struct PanelServerRow: View {
    let server: VPNServer
    let isActive: Bool
    let canConnect: Bool
    let hasPassword: Bool
    let onConnect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            if canConnect { onConnect() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: server.iconName)
                    .frame(width: 20)
                    .foregroundColor(isActive ? .green : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                        .lineLimit(1)
                    Text(hasPassword ? server.host : "No password · click to edit")
                        .font(.caption)
                        .foregroundColor(hasPassword ? .secondary : .orange)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                } else if hovering && canConnect {
                    Text(hasPassword ? "Connect" : "Edit")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && canConnect ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // While a connection is up the other servers fade out: disconnect first
        .opacity(canConnect || isActive ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

// MARK: - Footer Button

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
