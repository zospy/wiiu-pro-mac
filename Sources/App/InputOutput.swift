import AppKit
import ApplicationServices
import CoreGraphics

/// Ce qu’un bouton de la manette déclenche sur le Mac.
struct OutputAction: Identifiable, Hashable {
    enum Kind: Hashable { case none, key(CGKeyCode), leftClick, rightClick }

    let id: String
    let label: String
    let kind: Kind

    static let none = OutputAction(id: "none", label: "Rien", kind: .none)

    // Codes de touches physiques Mac (position du clavier QWERTY / canadien français).
    static let all: [OutputAction] = {
        var list: [OutputAction] = [
            .none,
            OutputAction(id: "leftClick", label: "Clic gauche", kind: .leftClick),
            OutputAction(id: "rightClick", label: "Clic droit", kind: .rightClick),
            OutputAction(id: "up", label: "↑ Flèche haut", kind: .key(126)),
            OutputAction(id: "down", label: "↓ Flèche bas", kind: .key(125)),
            OutputAction(id: "left", label: "← Flèche gauche", kind: .key(123)),
            OutputAction(id: "right", label: "→ Flèche droite", kind: .key(124)),
            OutputAction(id: "return", label: "Entrée", kind: .key(36)),
            OutputAction(id: "space", label: "Espace", kind: .key(49)),
            OutputAction(id: "escape", label: "Échap", kind: .key(53)),
            OutputAction(id: "tab", label: "Tab", kind: .key(48)),
            OutputAction(id: "delete", label: "Effacer", kind: .key(51)),
        ]
        let letters: [(String, CGKeyCode)] = [
            ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4), ("I", 34),
            ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15),
            ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ]
        list += letters.map { OutputAction(id: "key\($0.0)", label: "Touche \($0.0)", kind: .key($0.1)) }
        let digits: [(String, CGKeyCode)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ]
        list += digits.map { OutputAction(id: "key\($0.0)", label: "Touche \($0.0)", kind: .key($0.1)) }
        return list
    }()

    static func with(id: String) -> OutputAction { all.first { $0.id == id } ?? .none }
}

/// Transforme l’état de la manette en touches du clavier et en mouvements de souris.
final class InputOutput {
    static let defaultMapping: [String: String] = [
        "A": "return", "B": "escape", "X": "space", "Y": "tab",
        "L": "keyQ", "R": "keyE", "ZL": "rightClick", "ZR": "leftClick",
        "-": "delete", "+": "keyP", "HOME": "none",
        "HAUT": "up", "BAS": "down", "GAUCHE": "left", "DROITE": "right",
        "L3": "none", "R3": "none",
    ]

    var mapping: [String: String]
    var leftStickAsArrows = true
    var rightStickAsMouse = true
    var mouseSpeed: Double = 14  // points par image à fond de stick
    var enabled = false {
        didSet { if !enabled { releaseAll() } }
    }

    private var active = Set<OutputAction>()
    private var rightStick = CGVector(dx: 0, dy: 0)
    private var mouseTimer: Timer?
    private let source = CGEventSource(stateID: .hidSystemState)

    init(mapping: [String: String]) {
        self.mapping = mapping
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.moveMouse() }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func action(for button: ProButtons) -> OutputAction {
        guard let name = ProButtons.names.first(where: { $0.0 == button })?.1 else { return .none }
        return OutputAction.with(id: mapping[name] ?? "none")
    }

    func update(_ state: ProState, pad: DSUServer.Pad) {
        var buttons = state.buttons
        if leftStickAsArrows {
            // Le stick gauche agit comme la croix directionnelle au-delà de la moitié de sa course.
            let x = Int(pad.lx) - 128, y = Int(pad.ly) - 128
            if x < -64 { buttons.insert(.left) }
            if x > 64 { buttons.insert(.right) }
            if y > 64 { buttons.insert(.up) }
            if y < -64 { buttons.insert(.down) }
        }
        rightStick = CGVector(dx: Self.curve(pad.rx), dy: -Self.curve(pad.ry))

        guard enabled else { return }
        var wanted = Set<OutputAction>()
        for (button, _) in ProButtons.names where buttons.contains(button) {
            let a = action(for: button)
            if a.kind != .none { wanted.insert(a) }
        }
        for a in active.subtracting(wanted) { post(a, down: false) }
        for a in wanted.subtracting(active) { post(a, down: true) }
        active = wanted
    }

    func releaseAll() {
        for a in active { post(a, down: false) }
        active.removeAll()
        rightStick = .zero
    }

    /// Zone morte de 15 %, puis réponse progressive.
    private static func curve(_ v: UInt8) -> Double {
        let n = (Double(v) - 128) / 127
        guard abs(n) > 0.15 else { return 0 }
        let m = (abs(n) - 0.15) / 0.85
        return (n < 0 ? -1 : 1) * m * m
    }

    private func post(_ action: OutputAction, down: Bool) {
        switch action.kind {
        case .none:
            break
        case .key(let code):
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        case .leftClick:
            postMouse(down ? .leftMouseDown : .leftMouseUp, button: .left)
        case .rightClick:
            postMouse(down ? .rightMouseDown : .rightMouseUp, button: .right)
        }
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton) {
        let location = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func moveMouse() {
        guard enabled, rightStickAsMouse, rightStick.dx != 0 || rightStick.dy != 0 else { return }
        guard let current = CGEvent(source: nil)?.location else { return }
        var target = CGPoint(x: current.x + rightStick.dx * mouseSpeed, y: current.y + rightStick.dy * mouseSpeed)
        // Garder le pointeur sur un écran (coordonnées globales, origine en haut à gauche).
        let bounds = NSScreen.screens.reduce(CGRect.null) { r, screen in
            let f = screen.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
            return r.union(CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height))
        }
        target.x = min(max(target.x, bounds.minX), bounds.maxX - 1)
        target.y = min(max(target.y, bounds.minY), bounds.maxY - 1)

        let leftDown = active.contains { $0.kind == .leftClick }
        let rightDown = active.contains { $0.kind == .rightClick }
        let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
                mouseButton: rightDown && !leftDown ? .right : .left)?
            .post(tap: .cghidEventTap)
    }
}
