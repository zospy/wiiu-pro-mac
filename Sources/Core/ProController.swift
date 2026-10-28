import Foundation
import IOBluetooth

/// Boutons de la manette Wii U Pro (masque interne, indépendant du câblage matériel).
struct ProButtons: OptionSet, Hashable {
    let rawValue: UInt32
    static let a      = ProButtons(rawValue: 1 << 0)
    static let b      = ProButtons(rawValue: 1 << 1)
    static let x      = ProButtons(rawValue: 1 << 2)
    static let y      = ProButtons(rawValue: 1 << 3)
    static let l      = ProButtons(rawValue: 1 << 4)
    static let r      = ProButtons(rawValue: 1 << 5)
    static let zl     = ProButtons(rawValue: 1 << 6)
    static let zr     = ProButtons(rawValue: 1 << 7)
    static let minus  = ProButtons(rawValue: 1 << 8)
    static let plus   = ProButtons(rawValue: 1 << 9)
    static let home   = ProButtons(rawValue: 1 << 10)
    static let up     = ProButtons(rawValue: 1 << 11)
    static let down   = ProButtons(rawValue: 1 << 12)
    static let left   = ProButtons(rawValue: 1 << 13)
    static let right  = ProButtons(rawValue: 1 << 14)
    static let lStick = ProButtons(rawValue: 1 << 15)
    static let rStick = ProButtons(rawValue: 1 << 16)

    static let names: [(ProButtons, String)] = [
        (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.l, "L"), (.r, "R"),
        (.zl, "ZL"), (.zr, "ZR"), (.minus, "-"), (.plus, "+"), (.home, "HOME"),
        (.up, "HAUT"), (.down, "BAS"), (.left, "GAUCHE"), (.right, "DROITE"),
        (.lStick, "L3"), (.rStick, "R3"),
    ]

    var description: String {
        let list = Self.names.filter { contains($0.0) }.map { $0.1 }
        return list.isEmpty ? "(aucun)" : list.joined(separator: " ")
    }
}

/// État décodé : sticks bruts sur 12 bits (centre ≈ 0x800, Y croissant vers le haut).
struct ProState: Equatable {
    var buttons: ProButtons = []
    var lx = 0x800, ly = 0x800, rx = 0x800, ry = 0x800
}

/// Appareil Bluetooth Classic vu pendant la recherche.
struct FoundDevice: Identifiable, Equatable {
    let address: String
    var name: String?
    var classOfDevice: UInt32
    var id: String { address }
    var looksLikeController: Bool { ProController.looksLikeController(name: name, classOfDevice: classOfDevice) }
}

/// Lit une manette Wii U Pro via la pile Bluetooth de macOS (IOBluetooth),
/// en ouvrant directement les canaux L2CAP HID comme le fait Dolphin pour les Wiimotes.
final class ProController: NSObject, IOBluetoothL2CAPChannelDelegate, IOBluetoothDeviceInquiryDelegate,
                           IOBluetoothDevicePairDelegate {
    static let psmControl: BluetoothL2CAPPSM = 0x11
    static let psmInterrupt: BluetoothL2CAPPSM = 0x13
    static let namePrefix = "Nintendo RVL-CNT"  // Wii U Pro (…-01-UC) et Wiimotes

    enum Phase { case idle, searching, connecting, ready }

    var onState: ((ProState) -> Void)?
    var onConnection: ((_ connected: Bool, _ address: String?) -> Void)?
    var onPhase: ((Phase) -> Void)?
    var onDeviceFound: ((FoundDevice) -> Void)?
    var verbose = false
    /// Mode « laisser au jeu » : l’app appaire et connecte la manette, puis ne l’ouvre pas,
    /// pour qu’un jeu basé sur SDL (WiiCompiled…) puisse la prendre en exclusivité.
    var leaveToGame = false {
        didSet { if leaveToGame != oldValue { switchMode() } }
    }

    private var fixedAddress: String?
    private var seen: [String: FoundDevice] = [:]
    private var nameRequested = Set<String>()
    private var device: IOBluetoothDevice?
    private var control: IOBluetoothL2CAPChannel?
    private var interrupt: IOBluetoothL2CAPChannel?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var pairing: IOBluetoothDevicePair?
    private var pinProxy: LegacyPINProxy?  // relais des demandes « sans code » (macOS 26)
    private var successfulPair: IOBluetoothDevicePair?  // gardé en vie pour que macOS termine la connexion HID
    private var hid: HIDLink?
    private var gameDevice: IOHIDDevice?  // manette connectée et laissée au jeu
    private var isConnected: Bool { hid != nil || gameDevice != nil }
    private var watcher: HIDWatcher?
    private var initTries = 0
    private var gotReport = false  // la manette a envoyé au moins un rapport sur cette connexion
    private var wakeLink: HIDLink?  // lien temporaire du mode « laisser au jeu »
    private var pinAttempt = 0
    private var ready = false
    private var lastState: ProState?
    private var generation = 0  // invalide les tâches différées d'une connexion précédente
    private var stopped = true

    init(address: String?) {
        fixedAddress = address
    }

    func start() {
        stopped = false
        startWatcher()
        guard !isConnected else { return }
        if let address = fixedAddress {
            guard let dev = IOBluetoothDevice(addressString: address) else {
                log("Adresse Bluetooth invalide : \(address)")
                stopped = true
                onPhase?(.idle)
                return
            }
            connect(dev)
        } else if pairedController != nil {
            waitForController()
        } else {
            startInquiry()
        }
    }

    /// Manette Nintendo déjà appairée à ce Mac, s’il y en a une.
    private var pairedController: IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first { $0.name?.hasPrefix(Self.namePrefix) == true }
    }

    /// Une manette appairée se connecte d’elle-même quand on appuie sur un bouton : le Mac ne peut pas
    /// l’appeler (elle ne répond pas à l’authentification). On attend donc sans lancer de recherche,
    /// qui gênerait la connexion entrante, puis on fait une courte recherche au cas où on appuie sur SYNC.
    private func waitForController() {
        guard !stopped, !isConnected else { return }
        device = nil
        onPhase?(.searching)
        log("En attente de la manette : appuyez sur un bouton (A, B…). Jamais appairée à ce Mac ? Appuyez sur SYNC.")
        generation += 1
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.generation == gen, !self.isConnected, !self.stopped, self.device == nil else { return }
            self.startInquiry()
        }
    }

    /// Connexion manuelle à un appareil précis (par exemple choisi dans la liste des appareils trouvés).
    func connect(address: String) {
        guard let dev = IOBluetoothDevice(addressString: address) else {
            log("Adresse Bluetooth invalide : \(address)")
            return
        }
        // Déjà en cours avec cette manette : ne rien couper (une déconnexion forcée pendant
        // l’authentification fait échouer la connexion et effacer la clé d’appairage).
        if !stopped, let current = device, current.addressString == dev.addressString {
            log("Connexion déjà en cours avec cette manette.")
            return
        }
        stopped = false
        fixedAddress = address
        stopInquiry()
        if device != nil { teardown() }
        device = dev
        // Laisser la recherche s’arrêter avant d’appeler la manette.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.connect(dev) }
    }

    /// Arrête la recherche, ferme les canaux et annule les reconnexions.
    func stop() {
        guard !stopped else { return }
        stopped = true
        stopInquiry()
        watcher?.stop()
        watcher = nil
        teardown()
        log("Arrêt de la connexion à la manette.")
        onPhase?(.idle)
    }

    // MARK: - Recherche

    /// La fin de recherche est signalée immédiatement par stop() : on oublie la recherche avant,
    /// pour que deviceInquiryComplete ne relance pas une recherche pendant la connexion.
    private func stopInquiry() {
        let inq = inquiry
        inquiry = nil
        inq?.stop()
    }

    private func startInquiry() {
        guard !stopped else { return }
        onPhase?(.searching)
        log("Recherche en cours : appuyez sur SYNC sous la manette.")
        let inq = IOBluetoothDeviceInquiry(delegate: self)!
        inq.inquiryLength = 8
        inq.updateNewDeviceNames = true
        inquiry = inq
        let r = inq.start()
        if r != kIOReturnSuccess {
            log("Échec du démarrage de la recherche : \(hex(r)). Nouvel essai dans 3 s.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startInquiry() }
        }
    }

    /// Nom Nintendo, ou classe « périphérique / manette ou joystick » quand le nom est encore inconnu.
    static func looksLikeController(name: String?, classOfDevice cod: UInt32) -> Bool {
        if let name, !name.isEmpty { return name.hasPrefix(namePrefix) }
        let major = (cod >> 8) & 0x1F
        let minor = (cod >> 2) & 0x0F
        return major == 0x05 && (minor == 0x01 || minor == 0x02)
    }

    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry!) {
        if verbose { log("Recherche Bluetooth démarrée par macOS.") }
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device dev: IOBluetoothDevice!) {
        considerFound(dev)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device dev: IOBluetoothDevice!, devicesRemaining: UInt32) {
        considerFound(dev)
    }

    private func considerFound(_ dev: IOBluetoothDevice) {
        guard let address = dev.addressString else { return }
        let found = FoundDevice(address: address, name: dev.name, classOfDevice: dev.classOfDevice)
        if seen[address] != found {
            seen[address] = found
            log("Appareil vu : \(address) « \(found.name ?? "nom inconnu") » classe 0x\(String(format: "%06X", found.classOfDevice))")
            onDeviceFound?(found)
        }
        guard device == nil, !stopped, !isConnected else { return }
        if found.looksLikeController {
            log("Manette détectée : \(address) « \(found.name ?? "sans nom") »")
            device = dev
            stopInquiry()
            if dev.isPaired() {
                // Trouvée en mode SYNC alors qu’elle est déjà appairée : souvent elle se reconnecte
                // d’elle-même dans la foulée. Sinon (ancienne clé refusée, ou première connexion
                // muette juste après l’appairage), on la réappaire : c’est ce qui la remet en route.
                log("Manette déjà appairée en mode SYNC : attente de sa reconnexion…")
                generation += 1
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.generation == gen, !self.isConnected, !self.stopped else { return }
                    if PrivatePairing.unpair(dev) {
                        log("Pas de reconnexion : remplacement de l’ancien appairage.")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.connect(dev, forcePair: true) }
                    } else {
                        self.connect(dev, forcePair: true)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.connect(dev) }
        } else if found.name == nil, !nameRequested.contains(address) {
            nameRequested.insert(address)
            dev.remoteNameRequest(self)
        }
    }

    @objc func remoteNameRequestComplete(_ dev: IOBluetoothDevice!, status: IOReturn) {
        guard let dev else { return }
        if status != kIOReturnSuccess && verbose {
            log("Lecture du nom de \(dev.addressString ?? "?") : \(hex(status))")
        }
        considerFound(dev)
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        guard sender === inquiry, !stopped else { return }
        inquiry = nil
        if device == nil {
            if error != kIOReturnSuccess {
                log("Recherche terminée avec l’erreur \(hex(error)).")
            } else {
                log("Aucune manette en mode SYNC (\(sender.foundDevices()?.count ?? 0) appareil(s) vu(s)).")
            }
            if pairedController != nil {
                waitForController()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startInquiry() }
            }
        }
    }

    // MARK: - Connexion L2CAP

    private func connect(_ dev: IOBluetoothDevice, forcePair: Bool = false) {
        guard !stopped else { return }
        onPhase?(.connecting)
        if device !== dev { pinAttempt = 0 }
        device = dev
        generation += 1
        if forcePair || !dev.isPaired() {
            pair(dev)
        } else {
            waitForController()
        }
    }

    // MARK: - Manette appairée (canaux HID gérés par macOS)

    private func startWatcher() {
        guard watcher == nil else { return }
        let w = HIDWatcher()
        w.onAppear = { [weak self] d in self?.hidAppeared(d) }
        w.onRemove = { [weak self] d in self?.hidDeviceGone(d) }
        watcher = w
        w.start()
    }

    private func hidAppeared(_ hidDevice: IOHIDDevice) {
        guard !stopped, !isConnected else { return }
        if leaveToGame {
            handOffToGame(hidDevice)
            return
        }
        guard let link = HIDLink(device: hidDevice) else { return }
        stopInquiry()
        hid = link
        link.onReport = { [weak self] bytes in self?.handleReport(bytes) }
        link.onRemoved = { [weak self] in self?.hidRemoved() }
        if let serial = link.serial, let dev = IOBluetoothDevice(addressString: serial.replacingOccurrences(of: "-", with: ":")) {
            if device?.addressString != dev.addressString { device = dev }
        }
        generation += 1
        initTries = 0
        onPhase?(.connecting)
        log("Manette connectée à macOS (« \(link.name) »). Initialisation…")
        gotReport = false
        let gen = generation
        wake(link, gen: gen) { [weak self] in self?.initializeWithRetry() }
    }

    /// Échanger avec la manette dès la connexion : si macOS passe la liaison en mode « sniff » avant
    /// le premier échange, la manette se tait puis la liaison meurt. On demande son état toutes les
    /// 100 ms jusqu’à la première réponse (3 s au plus), puis on continue.
    private func wake(_ link: HIDLink, gen: Int, tries: Int = 0, then done: @escaping () -> Void) {
        guard generation == gen, !stopped else { return }
        if gotReport || tries >= 30 {
            if !gotReport { log("La manette ne répond pas encore à la demande d’état.") }
            done()
            return
        }
        link.send([0x15, 0x00])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wake(link, gen: gen, tries: tries + 1, then: done)
        }
    }

    /// Change de mode sans couper la liaison Bluetooth (la couper oblige à réappairer).
    private func switchMode() {
        if leaveToGame, let link = hid {
            let wasReady = ready
            ready = false
            lastState = nil
            generation += 1
            link.onRemoved = nil
            link.close()
            hid = nil
            if wasReady { onConnection?(false, nil) }
            gameDevice = link.device
            log("Manette laissée au jeu, sans déconnexion.")
            onPhase?(.ready)
        } else if !leaveToGame, let hidDevice = gameDevice {
            wakeLink?.close()
            wakeLink = nil
            gameDevice = nil
            generation += 1
            hidAppeared(hidDevice)
        }
    }

    /// La manette est connectée à macOS : on ne l’ouvre pas (SDL l’ouvre en exclusivité) et on
    /// n’envoie aucune commande, le jeu l’initialise lui-même.
    private func handOffToGame(_ hidDevice: IOHIDDevice) {
        stopInquiry()
        gameDevice = hidDevice
        generation += 1
        let name = IOHIDDeviceGetProperty(hidDevice, kIOHIDProductKey as CFString) as? String ?? "manette"
        if let serial = IOHIDDeviceGetProperty(hidDevice, kIOHIDSerialNumberKey as CFString) as? String {
            device = IOBluetoothDevice(addressString: serial.replacingOccurrences(of: "-", with: ":"))
        }
        log("Manette connectée à macOS (« \(name) ») et laissée au jeu. Lancez le jeu (WiiCompiled…).")
        onPhase?(.ready)
        // Réveiller la manette tout de suite (voir wake), allumer le voyant 1 (sinon les 4 voyants
        // clignotent comme si elle n’était pas connectée), puis refermer pour laisser le jeu l’ouvrir.
        guard let link = HIDLink(device: hidDevice) else { return }
        wakeLink = link
        gotReport = false
        link.onReport = { [weak self] _ in self?.gotReport = true }
        let gen = generation
        wake(link, gen: gen) { [weak self] in
            let r = link.send([0x11, 0x10])
            if r != kIOReturnSuccess { log("Voyant joueur 1 : \(hex(r)).") }
            link.close()
            self?.wakeLink = nil
        }
    }

    private func hidDeviceGone(_ hidDevice: IOHIDDevice) {
        guard let current = gameDevice, CFEqual(current, hidDevice) else { return }
        gameDevice = nil
        generation += 1
        wakeLink?.close()
        wakeLink = nil
        device = nil
        log("Manette déconnectée.")
        waitForController()
    }

    private func initializeWithRetry() {
        initTries += 1
        initialize()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.generation == gen, !self.ready, self.hid != nil, !self.stopped else { return }
            if self.initTries < 6 {
                log("Pas encore de réponse de la manette, nouvel essai d’initialisation (\(self.initTries + 1)/6)…")
                self.initializeWithRetry()
            } else {
                log("La manette ne répond pas aux commandes. Éteignez-la (maintenez HOME) puis rallumez-la.")
            }
        }
    }

    private func hidRemoved() {
        log("Manette déconnectée.")
        let wasReady = ready
        ready = false
        lastState = nil
        generation += 1
        hid?.onRemoved = nil
        hid?.close()
        hid = nil
        device = nil
        if wasReady { onConnection?(false, nil) }
        // Juste après l’appairage, la manette coupe la première liaison puis se reconnecte d’elle-même.
        waitForController()
    }

    // MARK: - Appairage
    //
    // Les manettes Nintendo demandent un code binaire de 6 octets, impossible à taper dans la fenêtre
    // de macOS. Après un appui sur SYNC, ce code est l’adresse Bluetooth du Mac, octets inversés ;
    // en second essai on tente l’adresse de la manette inversée (méthode des Wiimotes avec 1+2).

    private func pair(_ dev: IOBluetoothDevice) {
        log("Appairage de la manette (le code est envoyé automatiquement)…")
        guard let p = IOBluetoothDevicePair(device: dev) else {
            openControl(dev)
            return
        }
        p.delegate = self
        PrivatePairing.enableUserDefinedPIN(p)
        pinProxy?.restore()
        pinProxy = nil
        if #available(macOS 26.0, *), pinAttempt == 0, let host = Self.hostAddress(),
           let proxy = PrivatePairing.installLegacyPINProxy(for: dev, key: PrivatePairing.key(from: Array(host.reversed()))) {
            proxy.onReply = {
                log("macOS a demandé un appairage « sans code » : code binaire envoyé à la place (adresse du Mac inversée).")
            }
            pinProxy = proxy
        }
        pairing = p
        let r = p.start()
        if r != kIOReturnSuccess {
            pinProxy?.restore()
            pinProxy = nil
            log("Impossible de lancer l’appairage : \(hex(r)). Tentative de connexion directe.")
            pairing = nil
            openControl(dev)
        }
    }

    /// Code d’appairage, ou nil si l’adresse nécessaire est introuvable (ne jamais envoyer un code nul).
    private func pinBytes(for dev: IOBluetoothDevice) -> [UInt8]? {
        let address = pinAttempt == 0 ? Self.hostAddress() : Self.parseAddress(dev.addressString)
        return address.map { Array($0.reversed()) }
    }

    private static func parseAddress(_ text: String?) -> [UInt8]? {
        let bytes = (text ?? "").split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 && bytes.contains(where: { $0 != 0 }) ? bytes : nil
    }

    /// Adresse Bluetooth du Mac. IOBluetoothHostController peut renvoyer une adresse vide si on
    /// l’interroge trop tôt après le lancement : on se rabat alors sur la dernière adresse connue,
    /// puis sur system_profiler.
    private static func hostAddress() -> [UInt8]? {
        let key = "hostBluetoothAddress"
        if let bytes = parseAddress(IOBluetoothHostController.default()?.addressAsString()) {
            UserDefaults.standard.set(bytes.map { String(format: "%02X", $0) }.joined(separator: ":"), forKey: key)
            return bytes
        }
        if let bytes = parseAddress(UserDefaults.standard.string(forKey: key)) { return bytes }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["SPBluetoothDataType"] as? [[String: Any]],
              let properties = entries.first?["controller_properties"] as? [String: Any],
              let bytes = parseAddress(properties["controller_address"] as? String) else { return nil }
        UserDefaults.standard.set(properties["controller_address"] as? String, forKey: key)
        return bytes
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let p = sender as? IOBluetoothDevicePair, let dev = device else { return }
        guard let bytes = pinBytes(for: dev) else {
            log("Adresse Bluetooth du Mac introuvable : appairage annulé (aucun code nul envoyé).")
            p.stop()
            return
        }
        let what = pinAttempt == 0 ? "adresse du Mac" : "adresse de la manette"
        if PrivatePairing.replyBinaryPIN(p, device: dev, bytes: bytes) {
            log("Code binaire envoyé directement (\(what) inversée : \(hexBytes(bytes))).")
            return
        }
        // Repli : API publique (peut abîmer les octets ≥ 0x80 sur les macOS récents).
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin) { buf in
            for (i, b) in bytes.prefix(buf.count).enumerated() { buf[i] = b }
        }
        log("Code envoyé par l’API publique (\(what) inversée : \(hexBytes(bytes))).")
        p.replyPINCode(bytes.count, pinCode: &pin)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let p = sender as? IOBluetoothDevicePair, p === pairing, let dev = device, !stopped else { return }
        pairing = nil
        pinProxy?.restore()
        pinProxy = nil
        if error == kIOReturnSuccess {
            log("Appairage réussi. Connexion à la manette…")
            successfulPair = p
            // macOS ouvre maintenant la connexion HID ; la manette sera signalée par la surveillance HID.
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.generation == gen, !self.isConnected else { return }
                self.waitForController()
            }
        } else if pinAttempt == 0 {
            pinAttempt = 1
            log("Appairage refusé (\(hex(error))). Essai avec l’autre code…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.device === dev, !self.stopped else { return }
                self.pair(dev)
            }
        } else {
            log("Appairage refusé (\(hex(error))). Tentative de connexion sans appairage.")
            openControl(dev)
        }
    }

    // MARK: - Canaux HID

    private func openControl(_ dev: IOBluetoothDevice) {
        guard !stopped, device === dev else { return }
        log("Ouverture du canal HID Control (PSM 0x11) vers \(dev.addressString ?? "?")…")
        var ch: IOBluetoothL2CAPChannel?
        let r = dev.openL2CAPChannelAsync(&ch, withPSM: Self.psmControl, delegate: self)
        control = ch
        if r != kIOReturnSuccess {
            fail("openL2CAPChannelAsync(0x11) a renvoyé \(hex(r))")
        }
    }

    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            fail("ouverture du PSM 0x\(String(channel.psm, radix: 16)) : \(hex(error))")
            return
        }
        if channel.psm == Self.psmControl {
            control = channel
            log("Canal Control ouvert. Ouverture du canal Interrupt (PSM 0x13)…")
            var ch: IOBluetoothL2CAPChannel?
            let r = device?.openL2CAPChannelAsync(&ch, withPSM: Self.psmInterrupt, delegate: self) ?? kIOReturnNotOpen
            interrupt = ch
            if r != kIOReturnSuccess { fail("openL2CAPChannelAsync(0x13) a renvoyé \(hex(r))") }
        } else if channel.psm == Self.psmInterrupt {
            interrupt = channel
            log("Canal Interrupt ouvert. Initialisation de la manette…")
            initialize()
        }
    }

    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        guard channel === control || channel === interrupt else { return }
        fail("canal PSM 0x\(String(channel.psm, radix: 16)) fermé")
    }

    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard channel === interrupt, dataLength >= 2 else { return }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        guard bytes[0] == 0xA1 else { return }
        handleReport(Array(bytes.dropFirst()))
    }

    private func fail(_ reason: String) {
        guard !isConnected else { return }  // une manette connectée en HID est gérée par la surveillance HID
        log("Déconnexion : \(reason)")
        let dev = teardown()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, self.device == nil else { return }
            if let dev, self.fixedAddress != nil {
                log("Nouvel essai de connexion (appuyez sur SYNC si la manette est éteinte).")
                self.connect(dev)
            } else {
                self.startInquiry()
            }
        }
    }

    @discardableResult
    private func teardown() -> IOBluetoothDevice? {
        let wasReady = ready
        ready = false
        lastState = nil
        generation += 1
        let dev = device
        pairing?.stop()
        pairing = nil
        pinProxy?.restore()
        pinProxy = nil
        successfulPair = nil
        gameDevice = nil
        wakeLink?.close()
        wakeLink = nil
        hid?.onRemoved = nil
        hid?.close()
        hid = nil
        control?.setDelegate(nil)
        interrupt?.setDelegate(nil)
        interrupt?.close()
        control?.close()
        control = nil
        interrupt = nil
        dev?.closeConnection()
        device = nil
        if wasReady { onConnection?(false, nil) }
        return dev
    }

    // MARK: - Protocole Wiimote / Pro Controller

    private func send(_ payload: [UInt8]) {
        if let hid {
            let r = hid.send(payload)
            if verbose { log("TX(HID) \(hexBytes(payload)) -> \(hex(r))") }
            if r != kIOReturnSuccess { log("Échec d’écriture HID \(hexBytes(payload)) : \(hex(r))") }
            return
        }
        guard let interrupt else { return }
        var packet: [UInt8] = [0xA2] + payload
        let r = packet.withUnsafeMutableBytes { buf in
            interrupt.writeSync(buf.baseAddress, length: UInt16(buf.count))
        }
        if verbose { log("TX \(hexBytes(packet)) -> \(hex(r))") }
        if r != kIOReturnSuccess { log("Échec d’écriture \(hexBytes(packet)) : \(hex(r))") }
    }

    private static func writeRegister(_ address: UInt32, _ value: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x16, 0x04, UInt8((address >> 16) & 0xFF), UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF), 0x01, value]
        p += [UInt8](repeating: 0, count: 15)  // le champ de données fait toujours 16 octets
        return p
    }

    private static let setReportMode: [UInt8] = [0x12, 0x00, 0x34]  // boutons + 19 octets d’extension

    private func initialize() {
        let steps: [[UInt8]] = [
            [0x11, 0x10],                         // LED joueur 1
            Self.writeRegister(0xA400F0, 0x55),   // désactive le chiffrement de l’extension (1/2)
            Self.writeRegister(0xA400FB, 0x00),   // (2/2)
            [0x17, 0x04, 0xA4, 0x00, 0xFA, 0x00, 0x06],  // lecture de l’identifiant d’extension
            Self.setReportMode,
        ]
        let gen = generation
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.send(step)
            }
        }
    }

    private func handleReport(_ r: [UInt8]) {
        gotReport = true
        if verbose && r[0] != 0x34 { log("RX \(hexBytes(r))") }
        switch r[0] {
        case 0x20 where r.count >= 7:
            log("État : extension=\(r[3] & 0x02 != 0 ? "oui" : "non") batterie=0x\(String(r[6], radix: 16))")
            send(Self.setReportMode)  // un rapport d’état remet le mode à 0x30
        case 0x21 where r.count >= 22:
            let err = r[3] & 0x0F
            let data = Array(r[6..<(6 + Int(r[3] >> 4) + 1)])
            log("Identifiant d’extension : \(hexBytes(data))\(err != 0 ? " (erreur \(err))" : "") — attendu 00 00 A4 20 01 20")
        case 0x22 where r.count >= 5:
            if r[4] != 0 { log("Erreur sur la commande 0x\(String(r[3], radix: 16)) : \(r[4])") }
        case 0x32...0x3F:
            let offsets: [UInt8: Int] = [0x34: 3, 0x35: 6, 0x3D: 1]
            guard let o = offsets[r[0]], r.count >= o + 11 else { return }
            decode(Array(r[o..<(o + 11)]))
        default:
            break
        }
    }

    /// Format des 11 premiers octets d’extension, une fois le chiffrement désactivé
    /// (même disposition que le pilote Linux hid-wiimote, bits actifs à 0).
    private func decode(_ e: [UInt8]) {
        func le(_ i: Int) -> Int { Int(e[i]) | (Int(e[i + 1]) << 8) & 0x0FFF }
        var s = ProState()
        s.lx = le(0); s.rx = le(2); s.ly = le(4); s.ry = le(6)
        let map: [(Int, UInt8, ProButtons)] = [
            (8, 0x80, .right), (8, 0x40, .down), (8, 0x20, .l), (8, 0x10, .minus),
            (8, 0x08, .home), (8, 0x04, .plus), (8, 0x02, .r),
            (9, 0x80, .zl), (9, 0x40, .b), (9, 0x20, .y), (9, 0x10, .a),
            (9, 0x08, .x), (9, 0x04, .zr), (9, 0x02, .left), (9, 0x01, .up),
            (10, 0x02, .lStick), (10, 0x01, .rStick),
        ]
        for (byte, mask, button) in map where e[byte] & mask == 0 {
            s.buttons.insert(button)
        }

        if !ready {
            ready = true
            log("Manette prête : les rapports de boutons arrivent.")
            onConnection?(true, device?.addressString)
            onPhase?(.ready)
        }
        if s.buttons != lastState?.buttons {
            log("Boutons : \(s.buttons.description)")
        }
        if verbose, let last = lastState,
           abs(s.lx - last.lx) + abs(s.ly - last.ly) + abs(s.rx - last.rx) + abs(s.ry - last.ry) > 64 {
            log("Sticks : G(\(s.lx), \(s.ly)) D(\(s.rx), \(s.ry))")
        }
        lastState = s
        onState?(s)
    }
}

/// Reçoit chaque ligne de journal horodatée (Terminal ou interface graphique).
var logSink: (String) -> Void = { line in
    print(line)
    fflush(stdout)
}

func log(_ message: String) {
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    logSink("[\(t)] \(message)")
}

func hex(_ r: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: r)) }
func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
