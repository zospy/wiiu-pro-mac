import SwiftUI
import AppKit

@main
struct WiiUProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Manette Wii U Pro") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 840, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }

    /// Vérification visuelle sans accès à l’écran : WIIUPRO_SNAPSHOT=/chemin.png lance la démo,
    /// dessine la fenêtre dans un PNG puis quitte.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["WIIUPRO_SNAPSHOT"] else { return }
        let model = AppModel.shared
        model.startDemo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let view = NSHostingView(rootView: ContentView().environmentObject(model).frame(width: 860, height: 760))
            view.frame = NSRect(x: 0, y: 0, width: 860, height: 760)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Modèle

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WiiUPro.log")

    @Published private(set) var phase: Bridge.Phase = .idle
    @Published private(set) var buttons: ProButtons = []
    @Published private(set) var pad = DSUServer.Pad()
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var devices: [FoundDevice] = []
    @Published private(set) var trusted = InputOutput.isTrusted
    @Published private(set) var mapping: [String: String]
    @Published var address: String {
        didSet { defaults.set(address, forKey: "address") }
    }
    @Published var verbose = false {
        didSet { bridge.verbose = verbose }
    }
    @Published var leftStickAsArrows: Bool {
        didSet { io.leftStickAsArrows = leftStickAsArrows; defaults.set(leftStickAsArrows, forKey: "leftStickAsArrows") }
    }
    @Published var rightStickAsMouse: Bool {
        didSet { io.rightStickAsMouse = rightStickAsMouse; defaults.set(rightStickAsMouse, forKey: "rightStickAsMouse") }
    }
    @Published var mouseSpeed: Double {
        didSet { io.mouseSpeed = mouseSpeed; defaults.set(mouseSpeed, forKey: "mouseSpeed") }
    }
    /// L’app connecte la manette puis la laisse à un jeu basé sur SDL (WiiCompiled…).
    @Published var leaveToGame: Bool {
        didSet {
            guard leaveToGame != oldValue else { return }
            defaults.set(leaveToGame, forKey: "leaveToGame")
            bridge.leaveToGame = leaveToGame
            log(leaveToGame ? "Mode : manette laissée au jeu." : "Mode : clavier et souris.")
            refreshOutput()
        }
    }

    private let defaults = UserDefaults.standard
    private let bridge = Bridge()
    private let io: InputOutput
    private var nextLineID = 0
    private var lastRefresh = Date.distantPast
    private var logFile: FileHandle?
    private var trustTimer: Timer?

    init() {
        let saved = defaults.dictionary(forKey: "mapping") as? [String: String] ?? [:]
        let mapping = InputOutput.defaultMapping.merging(saved) { _, new in new }
        self.mapping = mapping
        io = InputOutput(mapping: mapping)
        address = defaults.string(forKey: "address") ?? ""
        leftStickAsArrows = defaults.object(forKey: "leftStickAsArrows") as? Bool ?? true
        rightStickAsMouse = defaults.object(forKey: "rightStickAsMouse") as? Bool ?? true
        mouseSpeed = defaults.object(forKey: "mouseSpeed") as? Double ?? 14
        leaveToGame = defaults.bool(forKey: "leaveToGame")
        bridge.leaveToGame = leaveToGame
        io.leftStickAsArrows = leftStickAsArrows
        io.rightStickAsMouse = rightStickAsMouse
        io.mouseSpeed = mouseSpeed

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: Self.logURL)
        logSink = { [weak self] line in
            print(line)
            self?.logFile?.write(Data((line + "\n").utf8))
            DispatchQueue.main.async { self?.append(line) }
        }
        bridge.onPhase = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = p
                if p == .searching { self.devices.removeAll() }
                self.refreshOutput()
            }
        }
        bridge.onUpdate = { [weak self] s, p in self?.update(s, p) }
        bridge.onDeviceFound = { [weak self] d in
            DispatchQueue.main.async {
                guard let self else { return }
                if let i = self.devices.firstIndex(where: { $0.address == d.address }) {
                    self.devices[i] = d
                } else {
                    self.devices.append(d)
                }
            }
        }

        // L’autorisation Accessibilité peut être donnée pendant que l’app tourne.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = InputOutput.isTrusted
            if now != self.trusted {
                self.trusted = now
                log(now ? "Autorisation Accessibilité accordée : la manette contrôle le clavier et la souris."
                        : "Autorisation Accessibilité retirée.")
                self.refreshOutput()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer

        log("Journal enregistré dans \(Self.logURL.path)")

        // Se mettre tout de suite à l’écoute de la manette : il suffit d’ouvrir l’app et d’appuyer sur SYNC.
        if ProcessInfo.processInfo.environment["WIIUPRO_SNAPSHOT"] == nil {
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }
    }

    var isRunning: Bool { phase != .idle }

    func connect() {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        bridge.start(address: trimmed.isEmpty ? nil : trimmed, demo: false)
    }

    func connect(to device: FoundDevice) {
        bridge.connect(address: device.address)
    }

    /// Démo sans manette, utilisée seulement pour la capture d’écran de vérification.
    func startDemo() { bridge.start(address: nil, demo: true) }

    func stop() {
        io.enabled = false
        bridge.stop()
    }

    func requestTrust() { InputOutput.requestTrust() }

    func actionLabel(for button: ProButtons) -> String { io.action(for: button).label }

    func setAction(_ action: OutputAction, for button: ProButtons) {
        guard let name = ProButtons.names.first(where: { $0.0 == button })?.1 else { return }
        mapping[name] = action.id
        io.releaseAll()
        io.mapping = mapping
        defaults.set(mapping, forKey: "mapping")
    }

    func resetMapping() {
        io.releaseAll()
        mapping = InputOutput.defaultMapping
        io.mapping = mapping
        defaults.removeObject(forKey: "mapping")
    }

    func clearLog() { lines.removeAll() }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private func refreshOutput() {
        io.enabled = trusted && phase == .ready && !leaveToGame
    }

    private func append(_ line: String) {
        lines.append(LogLine(id: nextLineID, text: line))
        nextLineID += 1
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    /// Le clavier et la souris réagissent à chaque rapport ; l’affichage est limité à ~30 i/s.
    private func update(_ s: ProState, _ p: DSUServer.Pad) {
        io.update(s, pad: p)
        let now = Date()
        guard s.buttons != buttons || now.timeIntervalSince(lastRefresh) > 1.0 / 30 else { return }
        lastRefresh = now
        buttons = s.buttons
        pad = p
    }
}

// MARK: - Vues

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gamecontroller.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("Manette Wii U Pro")
                    .font(.title2.bold())
                Spacer()
                StatusBadge(phase: model.phase, leaveToGame: model.leaveToGame)
            }

            if !model.trusted && !model.leaveToGame {
                TrustBanner()
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 14) {
                    ConnectionPanel()
                    if !model.devices.isEmpty {
                        DevicesPanel()
                    }
                    OptionsPanel()
                }
                .frame(width: 320)
                if model.leaveToGame {
                    GameModePanel()
                } else {
                    ControllerPanel()
                }
            }

            LogPanel()
        }
        .padding(20)
    }
}

struct StatusBadge: View {
    let phase: Bridge.Phase
    var leaveToGame = false

    private var info: (String, Color) {
        switch phase {
        case .idle: ("Déconnectée", .gray)
        case .searching: ("Recherche… appuyez sur SYNC", .orange)
        case .connecting: ("Connexion…", .orange)
        case .ready: (leaveToGame ? "Manette connectée · laissée au jeu" : "Manette connectée", .green)
        case .demo: ("Démo", .blue)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(info.1).frame(width: 10, height: 10)
            Text(info.0).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(info.1.opacity(0.15), in: Capsule())
    }
}

struct TrustBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Autorisation nécessaire").font(.headline)
                Text("Pour que la manette tape des touches et bouge la souris, macOS doit autoriser « WiiU Pro » dans Réglages Système → Confidentialité et sécurité → Accessibilité. Cochez-la : l’app le détecte toute seule.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Autoriser…") { model.requestTrust() }
                .controlSize(.large)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ConnectionPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Adresse de la manette (facultatif)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Automatique : bouton SYNC", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(model.isRunning)

                if model.isRunning {
                    Button(role: .destructive) { model.stop() } label: {
                        Label("Arrêter", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button { model.connect() } label: {
                        Label("Connecter la manette", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }

                if model.phase == .searching || model.phase == .connecting {
                    Text("Appuyez sur le petit bouton rouge SYNC à l’arrière de la manette ; les voyants clignotent. Si elle apparaît ci-dessous sans se connecter, cliquez sur « Connecter » à côté.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
        } label: {
            Label("Connexion", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

struct DevicesPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                ForEach(model.devices) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.looksLikeController ? "gamecontroller.fill" : "dot.radiowaves.right")
                            .foregroundStyle(d.looksLikeController ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name ?? "Nom inconnu").font(.callout).lineLimit(1)
                            Text(d.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connecter") { model.connect(to: d) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Appareils trouvés", systemImage: "list.bullet")
        }
    }
}

struct OptionsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Utilisation", selection: $model.leaveToGame) {
                    Text("Clavier et souris").tag(false)
                    Text("Laisser au jeu").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                Group {
                    Toggle("Stick gauche = croix directionnelle", isOn: $model.leftStickAsArrows)
                    Toggle("Stick droit = souris", isOn: $model.rightStickAsMouse)
                    HStack {
                        Text("Vitesse").foregroundStyle(.secondary)
                        Slider(value: $model.mouseSpeed, in: 4...40)
                            .disabled(!model.rightStickAsMouse)
                    }
                    Button("Touches par défaut") { model.resetMapping() }
                        .controlSize(.small)
                }
                .disabled(model.leaveToGame)
            }

            .font(.callout)
            .padding(4)
        } label: {
            Label("Réglages", systemImage: "slider.horizontal.3")
        }
    }
}

struct GameModePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.phase == .ready ? "La manette est connectée et laissée au jeu."
                                            : "La manette sera laissée au jeu dès sa connexion.",
                      systemImage: model.phase == .ready ? "checkmark.circle.fill" : "hourglass")
                    .font(.headline)
                    .foregroundStyle(model.phase == .ready ? Color.green : Color.secondary)
                Text("L’app s’occupe seulement de l’appairage et de la connexion Bluetooth. Elle n’envoie aucune touche : le jeu lit lui-même la manette, comme une vraie manette (sticks analogiques compris).")
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Pour WiiCompiled / Retro Rewind").font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Connectez la manette ici (badge vert).")
                    Text("2. Lancez WiiCompiled, appuyez sur F10 et attribuez la manette Nintendo au joueur 1.")
                    Text("3. Laissez cette app ouverte : elle reconnecte la manette si elle se coupe.")
                }
                .font(.callout)
                Text("L’affichage en direct est désactivé dans ce mode : le jeu doit pouvoir ouvrir la manette seul.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Manette laissée au jeu", systemImage: "gamecontroller")
        }
    }
}

struct ControllerPanel: View {
    @EnvironmentObject var model: AppModel

    private let rows: [[(ProButtons, String)]] = [
        [(.zl, "ZL"), (.l, "L"), (.r, "R"), (.zr, "ZR")],
        [(.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→")],
        [(.y, "Y"), (.x, "X"), (.a, "A"), (.b, "B")],
        [(.minus, "−"), (.home, "HOME"), (.plus, "+")],
        [(.lStick, "L3"), (.rStick, "R3")],
    ]

    var body: some View {
        GroupBox {
            VStack(spacing: 16) {
                HStack(spacing: 40) {
                    StickView(title: model.leftStickAsArrows ? "Stick gauche · flèches" : "Stick gauche",
                              x: model.pad.lx, y: model.pad.ly, pressed: model.buttons.contains(.lStick))
                    StickView(title: model.rightStickAsMouse ? "Stick droit · souris" : "Stick droit",
                              x: model.pad.rx, y: model.pad.ry, pressed: model.buttons.contains(.rStick))
                }
                VStack(spacing: 8) {
                    ForEach(rows.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            ForEach(rows[i], id: \.1) { button, label in
                                Menu {
                                    ForEach(OutputAction.all) { action in
                                        Button(action.label) { model.setAction(action, for: button) }
                                    }
                                } label: {
                                    ButtonChip(label: label, action: model.actionLabel(for: button),
                                               pressed: model.buttons.contains(button))
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                    }
                }
                Text("Cliquez sur un bouton pour choisir la touche qu’il tape.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .opacity(model.phase == .ready || model.phase == .demo ? 1 : 0.6)
        } label: {
            Label("Manette en direct", systemImage: "gamecontroller")
        }
    }
}

struct StickView: View {
    let title: String
    let x: UInt8
    let y: UInt8
    let pressed: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(pressed ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
                Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 45, y: 0)); p.addLine(to: CGPoint(x: 45, y: 90))
                    p.move(to: CGPoint(x: 0, y: 45)); p.addLine(to: CGPoint(x: 90, y: 45))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .offset(x: (CGFloat(x) - 128) / 127 * 37, y: -(CGFloat(y) - 128) / 127 * 37)
            }
            .frame(width: 90, height: 90)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ButtonChip: View {
    let label: String
    let action: String
    let pressed: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.callout.bold())
            Text(action)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(0.75)
        }
        .padding(.horizontal, 4)
        .frame(width: 86, height: 42)
        .foregroundStyle(pressed ? Color.white : Color.primary)
        .background(pressed ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                HStack {
                    Toggle("Détails techniques", isOn: $model.verbose)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Copier") { model.copyLog() }
                    Button("Effacer") { model.clearLog() }
                }
                .font(.callout)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.lines) { line in
                                Text(line.text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.lines.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Journal", systemImage: "text.alignleft")
        }
        .frame(minHeight: 130)
    }
}
