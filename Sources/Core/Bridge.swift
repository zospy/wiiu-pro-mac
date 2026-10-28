import Foundation

/// Convertit un axe brut 12 bits en octet DSU (128 = centre).
/// Le centre est pris au premier rapport et l’amplitude s’élargit selon les valeurs observées.
struct AxisCalibration {
    var center: Int?
    var range = 1000

    mutating func map(_ raw: Int) -> UInt8 {
        if center == nil { center = abs(raw - 0x800) < 300 ? raw : 0x800 }
        let deviation = raw - center!
        range = max(range, abs(deviation))
        return UInt8(clamping: 128 + deviation * 127 / range)
    }
}

/// Relie la manette (ou la simulation) au serveur DSU. Utilisé par l’outil en ligne de commande et par l’app.
final class Bridge {
    enum Phase: Equatable { case idle, searching, connecting, ready, demo }

    let server = DSUServer()
    var verbose = false {
        didSet { server.verbose = verbose; controller?.verbose = verbose }
    }
    var leaveToGame = false {
        didSet { controller?.leaveToGame = leaveToGame }
    }
    var onPhase: ((Phase) -> Void)?
    var onUpdate: ((ProState, DSUServer.Pad) -> Void)?
    var onDeviceFound: ((FoundDevice) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }
    private var controller: ProController?
    private var axes = [AxisCalibration](repeating: AxisCalibration(), count: 4)
    private var heartbeat: Timer?
    private var demoTimer: Timer?

    func listen(port: UInt16) throws {
        try server.listen(port: port)
        log("Serveur DSU à l’écoute sur 127.0.0.1:\(port).")
        // Envoi périodique : garde les clients à jour même sans nouveau rapport de la manette.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.server.broadcast() }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    func start(address: String?, demo: Bool) {
        stop()
        if demo {
            startDemo()
            return
        }
        let c = ProController(address: address)
        c.verbose = verbose
        c.leaveToGame = leaveToGame
        c.onConnection = { [weak self] connected, addr in self?.setConnected(connected, address: addr) }
        c.onState = { [weak self] s in self?.publish(s) }
        c.onDeviceFound = { [weak self] d in self?.onDeviceFound?(d) }
        c.onPhase = { [weak self] p in
            switch p {
            case .idle: self?.phase = .idle
            case .searching: self?.phase = .searching
            case .connecting: self?.phase = .connecting
            case .ready: self?.phase = .ready
            }
        }
        controller = c
        c.start()
    }

    /// Connexion à un appareil précis : pendant une recherche, ou en partant de l’arrêt.
    func connect(address: String) {
        if let controller, phase == .searching || phase == .connecting {
            controller.connect(address: address)
        } else {
            start(address: address, demo: false)
        }
    }

    func stop() {
        controller?.stop()
        controller = nil
        if demoTimer != nil {
            demoTimer?.invalidate()
            demoTimer = nil
            setConnected(false, address: nil)
            log("Mode démo arrêté.")
        }
        phase = .idle
    }

    private func startDemo() {
        log("Mode démo : manette simulée sur l’emplacement 0.")
        setConnected(true, address: "00:00:00:00:00:01")
        phase = .demo
        var tick = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            tick += 1
            let angle = Double(tick) / 60 * 2 * .pi / 4
            var s = ProState()
            if (tick / 60) % 2 == 1 { s.buttons.insert(.a) }
            s.lx = 0x800 + Int(1000 * cos(angle))
            s.ly = 0x800 + Int(1000 * sin(angle))
            self?.publish(s)
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    private func setConnected(_ connected: Bool, address: String?) {
        server.connected = connected
        if let address {
            server.mac = address.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
            if server.mac.count != 6 { server.mac = [0, 0, 0, 0, 0, 1] }
        }
        if !connected {
            server.pad = DSUServer.Pad()
            axes = [AxisCalibration](repeating: AxisCalibration(), count: 4)
            onUpdate?(ProState(), server.pad)
        }
    }

    private func publish(_ s: ProState) {
        // Disposition par position : A (droite) = Rond, B (bas) = Croix, X (haut) = Triangle, Y (gauche) = Carré.
        var p = DSUServer.Pad()
        let b = s.buttons
        if b.contains(.left)   { p.buttons1 |= 0x80 }
        if b.contains(.down)   { p.buttons1 |= 0x40 }
        if b.contains(.right)  { p.buttons1 |= 0x20 }
        if b.contains(.up)     { p.buttons1 |= 0x10 }
        if b.contains(.plus)   { p.buttons1 |= 0x08 }
        if b.contains(.rStick) { p.buttons1 |= 0x04 }
        if b.contains(.lStick) { p.buttons1 |= 0x02 }
        if b.contains(.minus)  { p.buttons1 |= 0x01 }
        if b.contains(.y)      { p.buttons2 |= 0x80 }
        if b.contains(.b)      { p.buttons2 |= 0x40 }
        if b.contains(.a)      { p.buttons2 |= 0x20 }
        if b.contains(.x)      { p.buttons2 |= 0x10 }
        if b.contains(.r)      { p.buttons2 |= 0x08 }
        if b.contains(.l)      { p.buttons2 |= 0x04 }
        if b.contains(.zr)     { p.buttons2 |= 0x02 }
        if b.contains(.zl)     { p.buttons2 |= 0x01 }
        p.ps = b.contains(.home) ? 1 : 0
        p.lx = axes[0].map(s.lx)
        p.ly = axes[1].map(s.ly)
        p.rx = axes[2].map(s.rx)
        p.ry = axes[3].map(s.ry)
        server.pad = p
        server.broadcast()
        onUpdate?(s, p)
    }
}
