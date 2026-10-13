import SwiftUI
import Combine
import ServiceManagement

enum SettingsTab {
    case servers, permission, general, log
}

/// Asks the settings window to open the server editor, e.g. from the menu bar panel.
enum ServerEditorRequest: Equatable {
    case add
    case edit(String)
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var selectedServer: VPNServer?
    @State private var showingAddServer = false
    @State private var showingEditServer = false
    @State private var selectedTab: SettingsTab
    @State private var pendingEditor: ServerEditorRequest?
    @State private var serverToDelete: VPNServer?
    @State private var showingDeleteConfirm = false
    
    init(initialTab: SettingsTab = .servers, initialEditor: ServerEditorRequest? = nil) {
        _selectedTab = State(initialValue: initialTab)
        _pendingEditor = State(initialValue: initialEditor)
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            serversTab
                .tabItem {
                    Label("Servers", systemImage: "server.rack")
                }
                .tag(SettingsTab.servers)
            
            permissionTab
                .tabItem {
                    Label("Permission", systemImage: "lock.shield")
                }
                .tag(SettingsTab.permission)
            
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
            
            logTab
                .tabItem {
                    Label("Log", systemImage: "doc.text")
                }
                .tag(SettingsTab.log)
        }
        .frame(width: 540, height: 460)
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
                ServerEditView(viewModel: viewModel, server: server)
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
    
    // MARK: - Servers Tab
    
    private var serversTab: some View {
        VStack(spacing: 0) {
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
                            onEdit: {
                                selectedServer = server
                                showingEditServer = true
                            },
                            onDelete: {
                                serverToDelete = server
                                showingDeleteConfirm = true
                            }
                        )
                        .tag(server)
                        .listRowSeparator(.hidden)
                        .onTapGesture(count: 2) {
                            selectedServer = server
                            showingEditServer = true
                        }
                    }
                    .onMove(perform: viewModel.moveServers)
                }
                .listStyle(.inset)
                .id(viewModel.refreshID)
            }
            
            Divider()
            
            HStack {
                Button(action: { showingAddServer = true }) {
                    Label("Add server", systemImage: "plus")
                }
                
                Spacer()
                
                if !viewModel.servers.isEmpty {
                    Text("Double-click to edit, drag to reorder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    // MARK: - Permission Tab
    
    private var permissionTab: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: sudoersIcon)
                        .font(.system(size: 28))
                        .foregroundColor(sudoersTint)
                        .frame(width: 36)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sudoersStatusText)
                            .font(.headline)
                        if let detail = sudoersStatusDetail {
                            Text(detail)
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
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
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
        .formStyle(.grouped)
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
        case .managed, .external: return .green
        case .outdated, .missing: return .orange
        case .binaryNotFound: return .red
        case .none: return .secondary
        }
    }
    
    private var sudoersStatusText: String {
        switch viewModel.sudoersStatus {
        case .none: return "Checking…"
        case .managed: return "openfortivpn can start without a password"
        case .external: return "Allowed by a rule you added manually"
        case .outdated: return "The rule points to a different openfortivpn"
        case .missing: return "Not set up: connections will fail"
        case .binaryNotFound: return "openfortivpn not found"
        }
    }
    
    private var sudoersStatusDetail: String? {
        switch viewModel.sudoersStatus {
        case .managed, .outdated:
            return SudoersManager.rulePath
        case .external:
            return "Not managed by OpenFortiMac (e.g. /etc/sudoers.d/openfortivpn)"
        case .missing:
            return viewModel.resolvedOpenfortivpnPath
        case .binaryNotFound:
            return "Install it with brew install openfortivpn, or set its path in General."
        case .none:
            return nil
        }
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
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
                    Text("⚠️ Binary not found at this path")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            Section("Startup") {
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
            }
            
            Section("Config File") {
                HStack {
                    Text(ConfigManager.configPath.path)
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
        .formStyle(.grouped)
        .padding(.top, 8)
    }
    
    // MARK: - Log Tab
    
    private var logTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if viewModel.logs.isEmpty {
                            Text("No logs yet. Connect to a VPN to see activity.")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.logs.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            Divider()
            
            HStack {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.logs.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.logs.isEmpty)
                
                Button("Clear") {
                    viewModel.clearLogs()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.logs.isEmpty)
                
                Spacer()
                
                Button("Refresh") {
                    viewModel.loadLogs()
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if !viewModel.logs.isEmpty {
            proxy.scrollTo(viewModel.logs.count - 1, anchor: .bottom)
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let server: VPNServer
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.iconName)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.host):\(server.port) · \(server.username)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if KeychainHelper.read(for: server.id) == nil {
                Text("No password")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit Server")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.7))
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
}

// MARK: - Server Edit

struct ServerEditView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let server: VPNServer?
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "443"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var trustedCert: String = ""
    @State private var icon: String = VPNServer.defaultIcon
    @State private var validationError: String?
    
    var isEditing: Bool { server != nil }
    
    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Server" : "Add Server")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Form {
                TextField("Name:", text: $name)
                    .frame(width: 280)
                TextField("Host:", text: $host)
                    .frame(width: 280)
                TextField("Port:", text: $port)
                    .frame(width: 280)
                TextField("Username:", text: $username)
                    .frame(width: 280)
                SecureField("Password:", text: $password)
                    .frame(width: 280)
                TextField("Certificate (optional):", text: $trustedCert)
                    .frame(width: 280)
                    .font(.system(size: 11, design: .monospaced))
                LabeledContent("Icon:") {
                    HStack(spacing: 4) {
                        ForEach(VPNServer.iconChoices, id: \.self) { choice in
                            Button {
                                icon = choice
                            } label: {
                                Image(systemName: choice)
                                    .frame(width: 28, height: 24)
                                    .foregroundColor(icon == choice ? .accentColor : .secondary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(icon == choice ? Color.accentColor.opacity(0.15) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice)
                        }
                    }
                    .frame(width: 280, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            
            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(isEditing ? "Save" : "Add") {
                    if validate() {
                        saveServer()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 410)
        .onAppear {
            if let server = server {
                name = server.name
                host = server.host
                port = String(server.port)
                username = server.username
                password = KeychainHelper.read(for: server.id) ?? ""
                trustedCert = server.trustedCert ?? ""
                icon = server.iconName
            }
        }
    }
    
    private func validate() -> Bool {
        validationError = nil
        
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty || trimmedHost.contains(" ") {
            validationError = "Host cannot be empty or contain spaces"
            return false
        }
        
        guard let portInt = Int(port), portInt >= 1, portInt <= 65535 else {
            validationError = "Port must be a number between 1 and 65535"
            return false
        }
        
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationError = "Name cannot be empty"
            return false
        }
        
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationError = "Username cannot be empty"
            return false
        }
        
        host = trimmedHost
        
        return true
    }
    
    private func saveServer() {
        let portInt = Int(port) ?? 443
        
        let newServer = VPNServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host,
            port: portInt,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: nil,
            trustedCert: trustedCert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trustedCert.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            id: server?.id
        )
        
        if !password.isEmpty {
            _ = KeychainHelper.save(password: password, for: newServer.id)
        }
        
        if let existingServer = server {
            viewModel.updateServer(existingServer, with: newServer)
        } else {
            viewModel.addServer(newServer)
        }
    }
}

// MARK: - ViewModel

class SettingsViewModel: ObservableObject {
    @Published var servers: [VPNServer] = []
    @Published var logs: [String] = []
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
    
    @Published private(set) var sudoersStatus: SudoersStatus?
    @Published private(set) var sudoersError: String?
    @Published private(set) var sudoersBusy = false
    @Published private(set) var resolvedOpenfortivpnPath: String?

    var isOpenfortivpnValid: Bool {
        FileManager.default.isExecutableFile(atPath: openfortivpnPath)
    }

    private var logsObserver: NSObjectProtocol?
    private var pathObserver: AnyCancellable?

    init() {
        loadServers()
        loadLogs()
        openfortivpnPath = ConfigManager.shared.config.openfortivpnPath
        loadLaunchAtLogin()
        refreshSudoersStatus()

        // The path is saved on every keystroke, so wait for typing to settle before asking sudo
        pathObserver = $openfortivpnPath
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSudoersStatus()
            }

        logsObserver = NotificationCenter.default.addObserver(
            forName: .vpnStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadLogs()
        }
    }
    
    deinit {
        if let observer = logsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func loadServers() {
        servers = []
        servers = ConfigManager.shared.config.servers
    }
    
    func loadLogs() {
        logs = VPNManager.shared.connectionLogs
    }
    
    func clearLogs() {
        logs = []
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
    
    private func saveConfig() {
        ConfigManager.shared.saveServers(servers)
        NotificationCenter.default.post(name: .configChanged, object: nil)
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

    private func loadLaunchAtLogin() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
    
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
