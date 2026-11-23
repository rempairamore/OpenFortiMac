import SwiftUI
import Combine
import ServiceManagement
import UniformTypeIdentifiers

enum SettingsTab: CaseIterable, Identifiable {
    case servers, permission, general, log

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .servers: return "Servers"
        case .permission: return "Permission"
        case .general: return "General"
        case .log: return "Log"
        }
    }

    var icon: String {
        switch self {
        case .servers: return "server.rack"
        case .permission: return "lock.shield"
        case .general: return "gearshape"
        case .log: return "doc.text"
        }
    }
}

/// Asks the settings window to open the server editor, e.g. from the menu bar panel.
enum ServerEditorRequest: Equatable {
    case add
    case edit(String)
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var selectedServer: VPNServer?
    @State private var showingAddServer = false
    @State private var showingEditServer = false
    @State private var selectedTab: SettingsTab
    @State private var pendingEditor: ServerEditorRequest?
    @State private var serverToDelete: VPNServer?
    @State private var showingDeleteConfirm = false
    @State private var logSearch = ""

    /// This view is the root of its window, so it takes the colors from the source
    private var palette: Palette { themeManager.theme.palette }

    init(initialTab: SettingsTab = .servers, initialEditor: ServerEditorRequest? = nil) {
        _selectedTab = State(initialValue: initialTab)
        _pendingEditor = State(initialValue: initialEditor)
    }

    var body: some View {
        // Not a TabView: on macOS that draws a bezel line across the window with the tabs
        // sitting on it, which leaves an odd empty band on both sides
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selectedTab)
            Divider()
            Group {
                switch selectedTab {
                case .servers: serversTab
                case .permission: permissionTab
                case .general: generalTab
                case .log: logTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 700)
        .themed(.window)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openServerEditor)) { notification in
            if let request = notification.object as? ServerEditorRequest {
                openEditor(request)
            }
        }
        .onAppear {
            if let request = pendingEditor {
                pendingEditor = nil
                // Wait for the window to be on screen before presenting a sheet
                DispatchQueue.main.async { openEditor(request) }
            }
        }
        .sheet(isPresented: $showingAddServer, onDismiss: { viewModel.loadServers() }) {
            ServerEditView(viewModel: viewModel, server: nil)
        }
        .sheet(isPresented: $showingEditServer, onDismiss: { viewModel.loadServers() }) {
            if let server = selectedServer {
                // A new editor per server: its fields are loaded once, when it appears, so a sheet
                // reused for another server would save the previous server's values into it
                ServerEditView(viewModel: viewModel, server: server)
                    .id(server.id)
            }
        }
        .alert("Delete Server", isPresented: $showingDeleteConfirm, presenting: serverToDelete) { server in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let index = viewModel.servers.firstIndex(where: { $0.id == server.id }) {
                    viewModel.deleteServers(at: IndexSet(integer: index))
                    selectedServer = nil
                }
            }
        } message: { server in
            Text("Are you sure you want to delete \"\(server.name)\"?")
        }
    }

    private func openEditor(_ request: ServerEditorRequest) {
        selectedTab = .servers
        switch request {
        case .add:
            showingAddServer = true
        case .edit(let id):
            if let server = viewModel.servers.first(where: { $0.id == id }) {
                selectedServer = server
                showingEditServer = true
            }
        }
    }

    private func edit(_ server: VPNServer) {
        selectedServer = server
        showingEditServer = true
    }

    // MARK: - Servers Tab

    private var serversTab: some View {
        VStack(spacing: 0) {
            if let issue = viewModel.configIssue {
                configIssueBanner(issue)
            }

            if viewModel.servers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Add your first server")
                        .font(.headline)
                    Text("Host, port and username of your FortiGate SSL VPN.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Add server") { showingAddServer = true }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedServer) {
                    ForEach(viewModel.servers) { server in
                        ServerRowView(
                            server: server,
                            hasPassword: !viewModel.serversWithoutPassword.contains(server.id),
                            onEdit: { edit(server) },
                            onDelete: {
                                serverToDelete = server
                                showingDeleteConfirm = true
                            }
                        )
                        .tag(server)
                        .listRowSeparator(.hidden)
                        .onTapGesture(count: 2) { edit(server) }
                        .contextMenu {
                            Button("Edit") { edit(server) }
                            Button("Duplicate") { viewModel.duplicate(server) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                serverToDelete = server
                                showingDeleteConfirm = true
                            }
                        }
                    }
                    .onMove(perform: viewModel.moveServers)
                }
                .listStyle(.inset)
                .themedForm()
                .id(viewModel.refreshID)
            }

            Divider()

            HStack {
                Button(action: { showingAddServer = true }) {
                    Label("Add server", systemImage: "plus")
                }

                Menu {
                    Button("Import servers…") { importServers() }
                    Button("Export servers…") { exportServers() }
                        .disabled(viewModel.servers.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Import or export servers")

                Spacer()

                if let message = viewModel.transferMessage {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !viewModel.servers.isEmpty {
                    Text("Double-click to edit, drag to reorder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(palette.bar)
        }
    }

    private func configIssueBanner(_ issue: ConfigIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                switch issue {
                case .unreadable:
                    Text("config.json could not be read")
                        .font(.callout.weight(.medium))
                    Text("Your servers are not shown. A copy of the file was kept.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .skippedServers:
                    Text("Some servers were left out")
                        .font(.callout.weight(.medium))
                    Text("They are incomplete in config.json. A copy of the file was kept.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let backup = issue.backup {
                    Text(verbatim: backup)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Show") { viewModel.revealConfigFolder() }
                .controlSize(.small)
        }
        .padding(10)
        .background(palette.warning.opacity(0.14))
    }

    private func importServers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a file exported from OpenFortiMac. Passwords are not part of it.")
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importServers(from: url)
        }
    }

    private func exportServers() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenFortiMac servers.json"
        panel.message = String(localized: "Passwords are not exported: they stay in your Keychain.")
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.exportServers(to: url)
        }
    }

    // MARK: - Permission Tab

    private var permissionTab: some View {
        Form {
            // One call colors the rows of every section
            Group {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: sudoersIcon)
                            .font(.system(size: 28))
                            .foregroundColor(sudoersTint)
                            .frame(width: 36)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: sudoersStatusText)
                                .font(.headline)
                            if let detail = sudoersStatusDetail {
                                Text(verbatim: detail)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        Spacer()

                        if viewModel.sudoersBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 6)

                    if let actions = sudoersActions {
                        HStack {
                            Spacer()
                            actions
                        }
                    }

                    if let error = viewModel.sudoersError {
                        Text(verbatim: error)
                            .font(.caption)
                            .foregroundColor(palette.bad)
                    }
                }

                Section("How it works") {
                    Text("openfortivpn needs root to create the VPN tunnel. OpenFortiMac adds a sudo rule so it can start without asking for your password every time.")
                        .font(.callout)
                    Text("Any app running as your user gains the same ability. Remove the rule if you stop using OpenFortiMac.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .listRowBackground(palette.row)
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.top, 8)
    }

    private var sudoersActions: AnyView? {
        let busy = viewModel.sudoersBusy
        switch viewModel.sudoersStatus {
        case .missing:
            return AnyView(
                Button("Set Up…") { viewModel.setUpSudoers() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            )
        case .outdated:
            return AnyView(HStack {
                Button("Remove") { viewModel.removeSudoers() }
                    .disabled(busy)
                Button("Update…") { viewModel.setUpSudoers() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            })
        case .managed:
            return AnyView(
                Button("Remove") { viewModel.removeSudoers() }
                    .disabled(busy)
            )
        case .binaryNotFound:
            return AnyView(
                Button("Open General") { selectedTab = .general }
            )
        default:
            return nil
        }
    }

    private var sudoersIcon: String {
        switch viewModel.sudoersStatus {
        case .managed, .external: return "checkmark.shield.fill"
        case .outdated, .missing: return "exclamationmark.shield.fill"
        case .binaryNotFound: return "xmark.shield.fill"
        case .none: return "shield"
        }
    }

    private var sudoersTint: Color {
        switch viewModel.sudoersStatus {
        case .managed, .external: return palette.good
        case .outdated, .missing: return palette.warning
        case .binaryNotFound: return palette.bad
        case .none: return .secondary
        }
    }

    private var sudoersStatusText: String {
        switch viewModel.sudoersStatus {
        case .none: return String(localized: "Checking…")
        case .managed: return String(localized: "openfortivpn can start without a password")
        case .external: return String(localized: "Allowed by a rule you added manually")
        case .outdated: return String(localized: "The rule points to a different openfortivpn")
        case .missing: return String(localized: "Not set up: connections will fail")
        case .binaryNotFound: return String(localized: "openfortivpn not found")
        }
    }

    private var sudoersStatusDetail: String? {
        switch viewModel.sudoersStatus {
        case .managed, .outdated:
            return SudoersManager.rulePath
        case .external:
            return String(localized: "Not managed by OpenFortiMac (e.g. /etc/sudoers.d/openfortivpn)")
        case .missing:
            return viewModel.resolvedOpenfortivpnPath
        case .binaryNotFound:
            return String(localized: "Install it with brew install openfortivpn, or set its path in General.")
        case .none:
            return nil
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            // One call colors the rows of every section
            Group {
                Section("openfortivpn Binary") {
                    HStack {
                        TextField("Path:", text: $viewModel.openfortivpnPath)
                            .font(.system(.body, design: .monospaced))

                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
                            if panel.runModal() == .OK, let url = panel.url {
                                viewModel.openfortivpnPath = url.path
                            }
                        }
                    }

                    if !viewModel.isOpenfortivpnValid {
                        Label("Binary not found at this path", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(palette.warning)
                    }
                }

                Section("Startup") {
                    Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $themeManager.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.name).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Language", selection: $viewModel.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.name).tag(language)
                        }
                    }
                    // The interface changes language only when the app starts
                    if viewModel.languageNeedsRestart {
                        HStack {
                            Group {
                                if vpn.isActive {
                                    Text("Restart OpenFortiMac to apply. The VPN will disconnect.")
                                } else {
                                    Text("Restart OpenFortiMac to apply.")
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            Spacer()
                            Button("Restart Now") { AppLanguage.restartApp() }
                        }
                    }
                }

                Section("Updates") {
                    LabeledContent("Version") {
                        Text(verbatim: PanelViewModel.appVersion)
                            .textSelection(.enabled)
                    }
                    Toggle("Check for updates automatically", isOn: $viewModel.checkForUpdates)
                    HStack {
                        updateStatusText
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if case .available(let update) = viewModel.updateStatus {
                            Button("Update") { NSWorkspace.shared.open(update.page) }
                        }
                        Button("Check Now") { viewModel.checkForUpdatesNow() }
                            .disabled(viewModel.updateStatus == .checking)
                    }
                }

                Section("Config File") {
                    HStack {
                        Text(verbatim: ConfigManager.configPath.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        Spacer()

                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(
                                ConfigManager.configPath.path,
                                inFileViewerRootedAtPath: ConfigManager.configPath.deletingLastPathComponent().path
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listRowBackground(palette.row)
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.top, 8)
    }

    @ViewBuilder
    private var updateStatusText: some View {
        switch viewModel.updateStatus {
        case .idle:
            Text("Asks GitHub for the latest release, once a day.")
        case .checking:
            Text("Checking…")
        case .upToDate:
            Text("OpenFortiMac is up to date.")
        case .available(let update):
            Text("Version \(update.version) is available")
        case .failed:
            Text("Could not reach GitHub.")
        }
    }

    // MARK: - Log Tab

    private var shownLogs: [LogEntry] {
        let search = logSearch.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return vpn.logs }
        return vpn.logs.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private var logTab: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if vpn.logs.isEmpty {
                            Text("No logs yet. Connect to a VPN to see activity.")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(shownLogs) { entry in
                                LogRow(entry: entry)
                                    .id(entry.id)
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                .background(palette.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                .overlay(alignment: .topTrailing) {
                    if vpn.isActive {
                        liveBadge
                            .padding(8)
                    }
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: vpn.logs.last?.id) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            HStack(spacing: 16) {
                TextField("Search…", text: $logSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .disabled(vpn.logs.isEmpty)

                Button("Save…") { saveLog() }
                    .disabled(vpn.logs.isEmpty)

                Button("Clear") { vpn.clearLogs() }
                    .disabled(vpn.logs.isEmpty)
            }
            .buttonStyle(TextLinkStyle())
        }
        .padding(12)
    }

    /// The log follows the connection by itself while one is active.
    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(palette.good)
                .frame(width: 7, height: 7)
            Text("live")
                .font(.caption.weight(.medium))
                .foregroundColor(palette.good)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.inset))
    }

    private var logText: String {
        shownLogs.map(\.text).joined(separator: "\n")
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "OpenFortiMac log.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? (logText + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = shownLogs.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - Tab Bar

/// The tabs of the Settings window, drawn like the toolbar of a preferences window.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11, weight: selection == tab ? .semibold : .regular))
                    }
                    .foregroundColor(selection == tab ? palette.accent : .secondary)
                    .frame(width: 84, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == tab ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Text Link

/// A text button in the theme's accent color.
private struct TextLinkStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(palette.accent)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - Log Row

private struct LogRow: View {
    let entry: LogEntry
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: entry.time)
                .foregroundColor(.secondary)
            Text(verbatim: entry.tag)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 34)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(entry.level == .info ? 0.12 : 0.2))
                )
            Text(verbatim: entry.message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var color: Color {
        switch entry.level {
        case .info: return .secondary
        case .ok: return palette.good
        case .warning: return palette.warning
        case .error: return palette.bad
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    @Environment(\.palette) private var palette
    let server: VPNServer
    let hasPassword: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.iconName)
                .font(.system(size: 15))
                .foregroundColor(palette.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.name)
                    .font(.headline)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !hasPassword {
                Text("No password")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(palette.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.warning.opacity(0.15)))
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit Server")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(palette.bad.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help("Delete Server")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let address = "\(server.host):\(server.port)"
        if server.singleSignOn {
            return "\(address) · \(String(localized: "Single sign-on"))"
        }
        return "\(address) · \(server.username)"
    }
}

// MARK: - Server Edit

struct ServerEditView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let server: VPNServer?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "443"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var hasSavedPassword = false
    @State private var icon: String = VPNServer.defaultIcon
    @State private var trustedCert: String = ""
    @State private var realm: String = ""
    @State private var alwaysAskCode = false
    /// Empty keeps openfortivpn's default
    @State private var minTLS: String = ""
    @State private var singleSignOn = false
    @State private var showAdvanced = false
    @State private var validationError: String?

    var isEditing: Bool { server != nil }
    private var palette: Palette { themeManager.theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            // LocalizedStringKey on both sides: a ternary of plain literals is not translated
            Text(isEditing ? LocalizedStringKey("Edit Server") : LocalizedStringKey("Add Server"))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 18)
                .padding(.bottom, 2)

            Form {
                // One call colors the rows of every section
                Group {
                    Section {
                        TextField("Name", text: $name)
                        TextField("Host", text: $host, prompt: Text(verbatim: "vpn.example.com"))
                        TextField("Port", text: $port)
                        if !singleSignOn {
                            TextField("Username", text: $username)
                            // The saved password is never loaded into the field
                            SecureField("Password", text: $password,
                                        prompt: hasSavedPassword ? Text("Saved · leave empty to keep") : nil)
                        }
                        LabeledContent("Icon") {
                            iconPicker
                        }
                    }

                    // Options most servers never need: closed until asked for
                    Section {
                        if showAdvanced {
                            TextField("Certificate", text: $trustedCert, prompt: Text("optional"))
                            TextField("Realm", text: $realm, prompt: Text("optional"))
                            Picker("One-time code", selection: $alwaysAskCode) {
                                Text("Phone approval when available").tag(false)
                                Text("Ask when connecting").tag(true)
                            }
                            Picker("Minimum TLS", selection: $minTLS) {
                                Text("System default").tag("")
                                ForEach(VPNServer.tlsChoices, id: \.self) { version in
                                    Text(verbatim: "TLS \(version)").tag(version)
                                }
                            }
                            Toggle("Single sign-on (SAML)", isOn: $singleSignOn)
                        }
                    } header: {
                        Button {
                            showAdvanced.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 12)
                                Text("Advanced")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(palette.row)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)

            if let error = validationError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundColor(palette.bad)
                    .padding(.horizontal)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? LocalizedStringKey("Save") : LocalizedStringKey("Add")) {
                    if validate(), saveServer() {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || host.isEmpty || (username.isEmpty && !singleSignOn))
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        // One background from the title to the buttons, with the groups standing out on it
        .background(palette.backgroundColor ?? Color(NSColor.textBackgroundColor))
        .frame(width: 440, height: sheetHeight)
        .themed(.custom)
        .onAppear {
            if let server = server {
                name = server.name
                host = server.host
                port = String(server.port)
                username = server.username
                hasSavedPassword = KeychainHelper.exists(for: server.id)
                icon = server.iconName
                trustedCert = server.trustedCert ?? ""
                realm = server.realm ?? ""
                alwaysAskCode = server.alwaysAskCode
                minTLS = server.minTLS ?? ""
                singleSignOn = server.singleSignOn
                // Open the section when it already holds something
                showAdvanced = !trustedCert.isEmpty || !realm.isEmpty || alwaysAskCode || !minTLS.isEmpty || singleSignOn
            }
        }
    }

    /// The sheet follows what the form shows: Advanced open or closed, sign-in fields or not.
    private var sheetHeight: CGFloat {
        var height: CGFloat = 404
        if showAdvanced {
            height += 196
        }
        if singleSignOn {
            height -= 76
        }
        return height
    }

    private var iconPicker: some View {
        HStack(spacing: 4) {
            ForEach(VPNServer.iconChoices, id: \.self) { choice in
                Button {
                    icon = choice
                } label: {
                    Image(systemName: choice)
                        .frame(width: 28, height: 24)
                        .foregroundColor(icon == choice ? palette.accent : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(icon == choice ? palette.accent.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice)
            }
        }
    }

    private func validate() -> Bool {
        validationError = nil

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty || trimmedHost.contains(" ") {
            validationError = String(localized: "Host cannot be empty or contain spaces")
            return false
        }

        guard let portInt = Int(port), portInt >= 1, portInt <= 65535 else {
            validationError = String(localized: "Port must be a number between 1 and 65535")
            return false
        }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationError = String(localized: "Name cannot be empty")
            return false
        }

        if !singleSignOn && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationError = String(localized: "Username cannot be empty")
            return false
        }

        // These values become "key = value" lines of openfortivpn's config file
        let configValues = [trimmedHost, password] + [username, trustedCert, realm].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if configValues.contains(where: { $0.contains(where: \.isNewline) }) {
            validationError = String(localized: "Fields cannot contain line breaks")
            return false
        }

        host = trimmedHost

        return true
    }

    private func saveServer() -> Bool {
        let portInt = Int(port) ?? 443
        let trimmedCert = trustedCert.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRealm = realm.trimmingCharacters(in: .whitespacesAndNewlines)

        let newServer = VPNServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host,
            port: portInt,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            trustedCert: trimmedCert.isEmpty ? nil : trimmedCert,
            realm: trimmedRealm.isEmpty ? nil : trimmedRealm,
            icon: icon,
            minTLS: minTLS.isEmpty ? nil : minTLS,
            alwaysAskCode: alwaysAskCode,
            singleSignOn: singleSignOn,
            id: server?.id
        )

        if !password.isEmpty && !singleSignOn {
            guard KeychainHelper.save(password: password, for: newServer.id) else {
                validationError = String(localized: "The password could not be saved in the Keychain")
                return false
            }
        }

        if let existingServer = server {
            viewModel.updateServer(existingServer, with: newServer)
        } else {
            viewModel.addServer(newServer)
        }
        return true
    }
}

// MARK: - ViewModel

class SettingsViewModel: ObservableObject {
    enum UpdateStatus: Equatable {
        case idle, checking, upToDate, failed
        case available(AvailableUpdate)
    }

    @Published var servers: [VPNServer] = []
    @Published private(set) var serversWithoutPassword: Set<String> = []
    @Published private(set) var configIssue: ConfigIssue?
    /// Result of the last import or export, shown for a few seconds
    @Published private(set) var transferMessage: String?
    @Published var refreshID = UUID()
    @Published var openfortivpnPath: String = "" {
        didSet {
            if oldValue != openfortivpnPath {
                ConfigManager.shared.saveOpenfortivpnPath(openfortivpnPath)
            }
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            if oldValue != launchAtLogin {
                updateLaunchAtLogin()
            }
        }
    }
    /// Language for the next launch
    @Published var language = AppLanguage.selected {
        didSet {
            if oldValue != language {
                AppLanguage.selected = language
            }
        }
    }
    var languageNeedsRestart: Bool { language != AppLanguage.running }
    @Published var checkForUpdates: Bool = true {
        didSet {
            if oldValue != checkForUpdates {
                UpdateChecker.shared.isEnabled = checkForUpdates
                NotificationCenter.default.post(name: .updateSettingsChanged, object: nil)
            }
        }
    }
    @Published private(set) var updateStatus: UpdateStatus = .idle

    @Published private(set) var sudoersStatus: SudoersStatus?
    @Published private(set) var sudoersError: String?
    @Published private(set) var sudoersBusy = false
    @Published private(set) var resolvedOpenfortivpnPath: String?

    var isOpenfortivpnValid: Bool {
        FileManager.default.isExecutableFile(atPath: openfortivpnPath)
    }

    private var pathObserver: AnyCancellable?

    init() {
        // Set through the wrappers: assigning the properties here would run their didSet
        // and rewrite config.json every time the window opens
        _openfortivpnPath = Published(initialValue: ConfigManager.shared.config.openfortivpnPath)
        _launchAtLogin = Published(initialValue: SMAppService.mainApp.status == .enabled)
        _checkForUpdates = Published(initialValue: UpdateChecker.shared.isEnabled)
        if let update = UpdateChecker.shared.knownUpdate, UpdateChecker.shared.isEnabled {
            _updateStatus = Published(initialValue: .available(update))
        }

        loadServers()
        refreshSudoersStatus()

        // The path is saved on every keystroke, so wait for typing to settle before asking sudo
        pathObserver = $openfortivpnPath
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSudoersStatus()
            }
    }

    func loadServers() {
        servers = []
        servers = ConfigManager.shared.config.servers
        configIssue = ConfigManager.shared.loadIssue
        refreshPasswordBadges()
    }

    /// Only asks the Keychain whether a password exists, never for the password itself.
    private func refreshPasswordBadges() {
        serversWithoutPassword = Set(servers.filter { !$0.singleSignOn && !KeychainHelper.exists(for: $0.id) }.map(\.id))
    }

    func addServer(_ server: VPNServer) {
        servers.append(server)
        saveConfig()
        refreshID = UUID()
    }

    func updateServer(_ oldServer: VPNServer, with newServer: VPNServer) {
        if let index = servers.firstIndex(where: { $0.id == oldServer.id }) {
            servers[index] = newServer
            saveConfig()
            refreshID = UUID()
        }
    }

    func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            KeychainHelper.delete(for: servers[index].id)
        }
        servers.remove(atOffsets: offsets)
        saveConfig()
        refreshID = UUID()
    }

    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        saveConfig()
    }

    /// Adds a copy right below the original, with the same saved password.
    func duplicate(_ server: VPNServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let copy = server.copy(named: String(localized: "\(server.name) copy"))
        if let password = KeychainHelper.read(for: server.id), !password.isEmpty {
            _ = KeychainHelper.save(password: password, for: copy.id)
        }
        servers.insert(copy, at: index + 1)
        saveConfig()
        refreshID = UUID()
    }

    private func saveConfig() {
        ConfigManager.shared.saveServers(servers)
        refreshPasswordBadges()
        NotificationCenter.default.post(name: .configChanged, object: nil)
    }

    func revealConfigFolder() {
        let folder = ConfigManager.configPath.deletingLastPathComponent()
        let file = configIssue?.backup.map { folder.appendingPathComponent($0) } ?? ConfigManager.configPath
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: - Import and export

    /// Writes the servers, without passwords, in the same format as config.json.
    func exportServers(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(ExportedServers(servers: servers)).write(to: url, options: .atomic)
            show(String(localized: "Exported \(servers.count) servers"))
        } catch {
            show(String(localized: "The file could not be written"))
        }
    }

    /// Adds the servers of an exported file (or of another config.json) as new entries.
    func importServers(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(AppConfig.self, from: data),
              !file.servers.isEmpty else {
            show(String(localized: "No servers found in the file"))
            return
        }
        // New identities: importing twice, or a file from this same Mac, never overwrites a server
        servers.append(contentsOf: file.servers.map { $0.copy() })
        saveConfig()
        refreshID = UUID()
        show(String(localized: "Imported \(file.servers.count) servers"))
    }

    private struct ExportedServers: Encodable {
        let servers: [VPNServer]
    }

    private func show(_ message: String) {
        transferMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.transferMessage == message {
                self?.transferMessage = nil
            }
        }
    }

    // MARK: - Updates

    func checkForUpdatesNow() {
        updateStatus = .checking
        UpdateChecker.shared.check { [weak self] reached in
            guard reached else {
                self?.updateStatus = .failed
                return
            }
            if let update = UpdateChecker.shared.knownUpdate {
                self?.updateStatus = .available(update)
            } else {
                self?.updateStatus = .upToDate
            }
            NotificationCenter.default.post(name: .updateSettingsChanged, object: nil)
        }
    }

    // MARK: - Administrator Permission

    func refreshSudoersStatus() {
        let path = VPNManager.shared.findOpenfortivpnBinary()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SudoersManager.shared.status(for: path)
            DispatchQueue.main.async {
                self?.resolvedOpenfortivpnPath = path
                self?.sudoersStatus = status
                NotificationCenter.default.post(name: .sudoersChanged, object: status)
            }
        }
    }

    func setUpSudoers() {
        guard let path = VPNManager.shared.findOpenfortivpnBinary() else { return }
        changeSudoers { try SudoersManager.shared.install(binaryPath: path) }
    }

    func removeSudoers() {
        changeSudoers { try SudoersManager.shared.remove() }
    }

    private func changeSudoers(_ change: @escaping () throws -> Void) {
        sudoersBusy = true
        sudoersError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message: String?
            do {
                try change()
            } catch SudoersError.cancelled {
                // The user closed the password dialog: nothing to report
            } catch {
                message = error.localizedDescription
            }

            DispatchQueue.main.async {
                self?.sudoersBusy = false
                self?.sudoersError = message
                self?.refreshSudoersStatus()
            }
        }
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.launchAtLogin = (SMAppService.mainApp.status == .enabled)
            }
        }
    }
}

#Preview {
    SettingsView()
}
