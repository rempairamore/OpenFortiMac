import SwiftUI
import Combine
import ServiceManagement

enum SettingsTab {
    case servers, general, log
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var selectedServer: VPNServer?
    @State private var showingAddServer = false
    @State private var showingEditServer = false
    @State private var selectedTab: SettingsTab
    @State private var serverToDelete: VPNServer?
    @State private var showingDeleteConfirm = false

    init(initialTab: SettingsTab = .servers) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            serversTab
                .tabItem {
                    Label("Servers", systemImage: "server.rack")
                }
                .tag(SettingsTab.servers)

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
        .frame(width: 540, height: 540)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
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
    
    // MARK: - Servers Tab
    
    private var serversTab: some View {
        VStack(spacing: 0) {
            List(selection: $selectedServer) {
                ForEach(viewModel.servers) { server in
                    HStack {
                        ServerRowView(server: server)
                        Spacer()
                        Button(action: {
                            serverToDelete = server
                            showingDeleteConfirm = true
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                        .help("Delete Server")
                    }
                    .contentShape(Rectangle())
                    .tag(server)
                    .onTapGesture(count: 2) {
                        selectedServer = server
                        showingEditServer = true
                    }
                }
                .onMove(perform: viewModel.moveServers)
            }
            .listStyle(.inset)
            .id(viewModel.refreshID)
            
            Divider()
            
            HStack {
                Button(action: { showingAddServer = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Server")
                
                Button(action: {
                    if selectedServer != nil {
                        showingEditServer = true
                    }
                }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(selectedServer == nil)
                .help("Edit Server")
                
                Spacer()
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
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

            Section("Administrator Permission") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sudoersStatusText)
                        if let detail = sudoersStatusDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Spacer()

                    if viewModel.sudoersBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    switch viewModel.sudoersStatus {
                    case .missing:
                        Button("Set Up…") { viewModel.setUpSudoers() }
                            .disabled(viewModel.sudoersBusy)
                    case .outdated:
                        Button("Update…") { viewModel.setUpSudoers() }
                            .disabled(viewModel.sudoersBusy)
                        Button("Remove") { viewModel.removeSudoers() }
                            .disabled(viewModel.sudoersBusy)
                    case .managed:
                        Button("Remove") { viewModel.removeSudoers() }
                            .disabled(viewModel.sudoersBusy)
                    default:
                        EmptyView()
                    }
                }

                if let error = viewModel.sudoersError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("openfortivpn needs root to create the tunnel. This sudo rule lets it start without a password prompt; any app running as your user gains the same ability.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    private var sudoersStatusText: String {
        switch viewModel.sudoersStatus {
        case .none: return "Checking…"
        case .managed: return "✅ Set up"
        case .external: return "✅ Allowed by a rule you added manually"
        case .outdated: return "⚠️ Rule points to a different openfortivpn path"
        case .missing: return "⚠️ Not set up: connections will fail"
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
        default:
            return nil
        }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.headline)
            HStack(spacing: 4) {
                Text("\(server.host):\(server.port)")
                Text("•")
                Text(server.username)
                if KeychainHelper.read(for: server.id) == nil {
                    Text("•")
                    Text("No password")
                        .foregroundColor(.orange)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
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
        .frame(width: 420, height: 360)
        .onAppear {
            if let server = server {
                name = server.name
                host = server.host
                port = String(server.port)
                username = server.username
                password = KeychainHelper.read(for: server.id) ?? ""
                trustedCert = server.trustedCert ?? ""
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
