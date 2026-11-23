import SwiftUI

/// Content of the popover shown when clicking the menu bar icon.
struct MenuPanelView: View {
    @ObservedObject var model: PanelViewModel
    @ObservedObject var vpn: VPNManager

    /// Rows shown before the server list starts scrolling
    private let maxVisibleServers = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusCard(vpn: vpn, model: model)
                .padding(12)

            let banners = self.banners
            if !banners.isEmpty {
                VStack(spacing: 8) {
                    ForEach(banners) { $0 }
                }
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

    // MARK: - Banners

    private var banners: [PanelBanner] {
        var list: [PanelBanner] = []

        switch model.configIssue {
        case .unreadable:
            list.append(PanelBanner(
                id: "config",
                title: "config.json could not be read",
                detail: "Your servers are not shown. A copy of the file was kept.",
                action: "Show"
            ) { model.revealConfigFolder() })
        case .skippedServers:
            list.append(PanelBanner(
                id: "config",
                title: "Some servers were left out",
                detail: "They are incomplete in config.json. A copy of the file was kept.",
                action: "Show"
            ) { model.revealConfigFolder() })
        case .none:
            break
        }

        if !model.leftoverTunnels.isEmpty {
            list.append(PanelBanner(
                id: "leftover",
                title: "A VPN is still running",
                detail: model.leftoverStopFailed
                    ? "It did not stop. Restart your Mac to close it."
                    : "Left over from a previous session.",
                action: "Stop it"
            ) { model.stopLeftoverTunnels() })
        }

        switch model.sudoersStatus {
        case .missing:
            list.append(PanelBanner(
                id: "permission",
                title: "Administrator permission not set up",
                detail: "openfortivpn needs it to start the tunnel.",
                action: "Set up"
            ) { model.openSettings(.permission, nil) })
        case .outdated:
            list.append(PanelBanner(
                id: "permission",
                title: "Permission points to another openfortivpn",
                detail: "Update the rule after moving openfortivpn.",
                action: "Update"
            ) { model.openSettings(.permission, nil) })
        case .binaryNotFound:
            list.append(PanelBanner(
                id: "permission",
                title: "openfortivpn not found",
                detail: "Install it with brew install openfortivpn.",
                action: "Settings"
            ) { model.openSettings(.general, nil) })
        default:
            break
        }

        if let update = model.availableUpdate {
            list.append(PanelBanner(
                id: "update",
                style: .news,
                title: "Version \(update.version) is available",
                detail: "You have \(PanelViewModel.appVersion).",
                action: "Update"
            ) { model.openUpdatePage() })
        }

        return list
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

            Text(verbatim: "OpenFortiMac \(PanelViewModel.appVersion)")
                .font(.caption2)
                .foregroundColor(.secondary)

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
    let model: PanelViewModel

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
                        Image(systemName: isConnected ? "lock.fill" : "lock.open.fill")
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
                    Button("Disconnect") { model.disconnect() }
                        .keyboardShortcut("d", modifiers: .command)
                case .connecting:
                    Button("Cancel") { model.disconnect() }
                default:
                    EmptyView()
                }
            }

            if let failure = failure {
                FailureBox(failure: failure, model: model)
            }

            switch vpn.pendingInput {
            case .code:
                CodeEntry { vpn.submitCode($0) }
            case .browserSignIn:
                HStack {
                    Text("Complete the sign-in in your browser.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    Button("Open sign-in page") { vpn.reopenSignInPage() }
                        .controlSize(.small)
                }
            case .none:
                EmptyView()
            }

            if isConnected, let server = vpn.currentServer {
                details(for: server)
            }
        }
    }

    /// IP, traffic and gateway of the tunnel that is up.
    private func details(for server: VPNServer) -> some View {
        VStack(spacing: 6) {
            if let ip = vpn.assignedIP {
                DetailRow(label: "IP address", value: ip)
            }
            if let traffic = vpn.traffic {
                DetailRow(label: "Received", value: Self.bytes(traffic.received))
                DetailRow(label: "Sent", value: Self.bytes(traffic.sent))
            }
            DetailRow(label: "Gateway", value: "\(server.host):\(server.port)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var failure: ConnectionFailure? {
        vpn.state == .disconnected ? vpn.lastFailure : nil
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
        case .disconnected: return failure == nil ? .secondary : .red
        }
    }

    private var title: String {
        switch vpn.state {
        case .disconnected: return String(localized: "Not connected")
        case .connected(let serverName): return serverName
        case .connecting, .disconnecting: return vpn.currentServer?.name ?? "VPN"
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch vpn.state {
        case .disconnected:
            // Two Text literals: a ternary would pick the non-localized initializer
            if failure == nil {
                Text("Choose a server to connect")
            } else {
                Text("Last attempt failed")
            }
        case .connecting:
            switch vpn.pendingInput {
            case .code: Text("Waiting for your code…")
            case .browserSignIn: Text("Waiting for your browser…")
            case .none: Text("Connecting…")
            }
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

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

private struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

// MARK: - Failure

/// Why the last attempt failed, with what to do next.
private struct FailureBox: View {
    let failure: ConnectionFailure
    let model: PanelViewModel

    @State private var confirmingTrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: failure.title)
                .font(.callout.weight(.semibold))
            Text(verbatim: failure.detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if confirmingTrust, case .untrustedCertificate(let digest?, let subject) = failure.kind {
                trustConfirmation(digest: digest, subject: subject)
            } else {
                HStack(spacing: 14) {
                    link("Show log") { model.openSettings(.log, nil) }
                    if failure.kind == .authentication {
                        link("Edit server") { model.openSettings(.servers, .edit(failure.serverID)) }
                    }
                    if case .untrustedCertificate(_?, _) = failure.kind {
                        link("Trust this certificate…") { confirmingTrust = true }
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.13))
        )
    }

    /// Trusting is never one click: the fingerprint is shown first, to compare it.
    private func trustConfirmation(digest: String, subject: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let subject = subject {
                Text(verbatim: subject)
                    .font(.caption.weight(.medium))
            }
            Text(verbatim: Self.grouped(digest))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Trust it only if this is the fingerprint your administrator gave you.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { confirmingTrust = false }
                Button("Trust and connect") { model.trustCertificateAndConnect() }
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private func link(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// "ab12cd34 ef56…": eight characters at a time are easier to compare.
    static func grouped(_ digest: String) -> String {
        stride(from: 0, to: digest.count, by: 8).map { offset -> String in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            let end = digest.index(start, offsetBy: 8, limitedBy: digest.endIndex) ?? digest.endIndex
            return String(digest[start..<end])
        }.joined(separator: " ")
    }
}

// MARK: - Two-factor code

private struct CodeEntry: View {
    let onSend: (String) -> Void

    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Two-factor code")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("", text: $code)
                    .labelsHidden()
                    .accessibilityLabel("Two-factor code")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("From your authenticator app, email or SMS.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSend(code)
        code = ""
    }
}

// MARK: - Banner

private struct PanelBanner: View, Identifiable {
    enum Style {
        /// Something needs attention
        case warning
        /// Good to know, nothing is wrong
        case news
    }

    let id: String
    var style: Style = .warning
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: LocalizedStringKey
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style == .warning ? "exclamationmark.circle.fill" : "arrow.up.circle.fill")
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action, action: onAction)
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.14))
        )
    }

    private var tint: Color {
        style == .warning ? .orange : .blue
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
                    Text(verbatim: server.name)
                        .lineLimit(1)
                    Group {
                        if hasPassword {
                            Text(verbatim: server.host)
                        } else {
                            Text("No password · click to edit")
                        }
                    }
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
                    Group {
                        if hasPassword {
                            Text("Connect")
                        } else {
                            Text("Edit")
                        }
                    }
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
    let help: LocalizedStringKey
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
