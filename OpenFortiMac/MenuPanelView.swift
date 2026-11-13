import SwiftUI

/// Content of the popover shown when clicking the menu bar icon.
struct MenuPanelView: View {
    @ObservedObject var model: PanelViewModel
    @ObservedObject var vpn: VPNManager

    /// Rows shown before the server list starts scrolling
    private let maxVisibleServers = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tunnelCards
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

    // MARK: - Tunnel cards (one per active tunnel)

    @ViewBuilder
    private var tunnelCards: some View {
        if vpn.tunnels.isEmpty {
            TunnelCard(
                title: "Not connected",
                subtitle: AnyView(Text("Choose a server to connect")),
                icon: VPNState.disconnected.iconSymbol(style: model.iconStyle),
                tint: .secondary,
                busy: false,
                details: nil,
                onDisconnect: nil,
                disconnectShortcut: false
            )
        } else {
            VStack(spacing: 8) {
                ForEach(vpn.tunnels) { tunnel in
                    TunnelCard(
                        title: tunnel.serverName,
                        subtitle: TunnelCard.subtitle(for: tunnel),
                        icon: tunnel.state.iconSymbol(style: model.iconStyle),
                        tint: tunnel.state.tint,
                        busy: tunnel.isBusy,
                        details: tunnelDetails(tunnel),
                        onDisconnect: { model.disconnect(serverID: tunnel.serverID) },
                        // ⌘D stays unambiguous: only with a single tunnel
                        disconnectShortcut: vpn.tunnels.count == 1
                    )
                }
            }
        }
    }

    private func tunnelDetails(_ tunnel: TunnelStatus) -> [TunnelCardDetail]? {
        guard tunnel.isConnected else { return nil }
        var details: [TunnelCardDetail] = []
        if let ip = tunnel.assignedIP {
            details.append(TunnelCardDetail(systemImage: "network", text: ip))
        }
        if let iface = tunnel.interface {
            details.append(TunnelCardDetail(systemImage: "cable.connector", text: iface))
        }
        if !tunnel.routes.isEmpty {
            details.append(TunnelCardDetail(systemImage: "arrow.triangle.branch", text: tunnel.routes.joined(separator: ", ")))
        }
        return details.isEmpty ? nil : details
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
        case .routesMissing:
            return SetupBanner(
                title: "Static routes need permission",
                detail: "Update the rule so routes can be added.",
                action: "Update"
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
                    tunnel: vpn.status(for: server.id),
                    hasPassword: !model.serversWithoutPassword.contains(server.id)
                ) {
                    model.toggle(server)
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

// MARK: - State helpers

extension VPNState {
    /// Status card symbol, matching the menu bar icon style.
    func iconSymbol(style: MenuBarIconStyle) -> String {
        switch (self, style) {
        case (.disconnected, .classic): return "lock.open"
        case (.connecting, .classic), (.disconnecting, .classic), (.reconnecting, .classic): return "arrow.triangle.2.circlepath"
        case (.connected, .classic): return "lock.fill"
        case (.disconnected, .monochrome): return "shield"
        case (.connecting, .monochrome), (.disconnecting, .monochrome), (.reconnecting, .monochrome): return "shield.lefthalf.filled"
        case (.connected, .monochrome): return "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting, .disconnecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        }
    }
}

// MARK: - Tunnel Card

private struct TunnelCardDetail {
    let systemImage: String
    let text: String
}

private struct TunnelCard: View {
    let title: String
    let subtitle: AnyView
    let icon: String
    let tint: Color
    let busy: Bool
    let details: [TunnelCardDetail]?
    let onDisconnect: (() -> Void)?
    let disconnectShortcut: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
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

                if let onDisconnect = onDisconnect {
                    if busy {
                        Button("Cancel", action: onDisconnect)
                    } else {
                        Button("Disconnect", action: onDisconnect)
                            .keyboardShortcut(disconnectShortcut ? KeyboardShortcut("d", modifiers: .command) : nil)
                    }
                }
            }

            if let details = details {
                // Short facts side by side, routes (possibly long) on their own line
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        ForEach(details.filter { $0.systemImage != "arrow.triangle.branch" }, id: \.systemImage) { detail in
                            Label(detail.text, systemImage: detail.systemImage)
                        }
                    }
                    ForEach(details.filter { $0.systemImage == "arrow.triangle.branch" }, id: \.systemImage) { detail in
                        Label(detail.text, systemImage: detail.systemImage)
                            .lineLimit(2)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    static func subtitle(for tunnel: TunnelStatus) -> AnyView {
        switch tunnel.state {
        case .disconnected:
            return AnyView(Text("Choose a server to connect"))
        case .connecting:
            return AnyView(Text("Connecting…"))
        case .disconnecting:
            return AnyView(Text("Disconnecting…"))
        case .reconnecting(let date):
            guard let date = date else {
                return AnyView(Text("Waiting for the network…"))
            }
            return AnyView(TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text("Reconnecting in \(max(0, Int(date.timeIntervalSince(context.date).rounded(.up))))s…")
                    .monospacedDigit()
            })
        case .connected:
            guard let since = tunnel.connectedSince else {
                return AnyView(Text("Connected"))
            }
            return AnyView(TimelineView(.periodic(from: since, by: 1)) { context in
                Text("Connected · \(Self.format(context.date.timeIntervalSince(since)))")
                    .monospacedDigit()
            })
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
    let tunnel: TunnelStatus?
    let hasPassword: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    private var stateText: String? {
        guard let tunnel = tunnel else { return nil }
        switch tunnel.state {
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected: return "Connected"
        case .disconnected: return nil
        }
    }

    private var tint: Color {
        guard let tunnel = tunnel else { return .secondary }
        return tunnel.state.tint
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: server.iconName)
                    .frame(width: 20)
                    .foregroundColor(tint == .secondary ? .secondary : tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                        .lineLimit(1)
                    if let stateText = stateText {
                        Text("\(server.host) · \(stateText)")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    } else {
                        Text(hasPassword ? server.host : "No password · click to edit")
                            .font(.caption)
                            .foregroundColor(hasPassword ? .secondary : .orange)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if let tunnel = tunnel {
                    Circle()
                        .fill(tunnel.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                } else if hovering {
                    Text(hasPassword ? "Connect" : "Edit")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
