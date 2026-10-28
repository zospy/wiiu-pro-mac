import Foundation
import IOBluetooth

/// Appairage avec un code binaire, comme l’outil officiel de Dolphin (dolphin-emu/WiimotePair).
///
/// `IOBluetoothDevicePair.replyPINCode` convertit le code en texte avant de l’envoyer à bluetoothd,
/// ce qui abîme les octets ≥ 0x80 du code des manettes Nintendo. On appelle donc directement
/// la méthode interne que replyPINCode utilise : `IOBluetoothCoreBluetoothCoordinator
/// pairPeer:forType:withKey:`. Ces API sont privées : chaque appel vérifie d’abord qu’elles existent.
enum PrivatePairing {
    /// Type d’appairage « code PIN hérité » attendu par les manettes Nintendo.
    static let legacyPINType: UInt = 6

    /// Demande à macOS de toujours passer par le délégué pour le code (pas de fenêtre système).
    static func enableUserDefinedPIN(_ pair: IOBluetoothDevicePair) {
        let sel = NSSelectorFromString("setUserDefinedPincode:")
        guard pair.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(pair.method(for: sel), to: Fn.self)(pair, sel, true)
    }

    /// Oublie l’appairage d’un appareil (méthode interne `remove`, utilisée aussi par blueutil --unpair).
    static func unpair(_ device: IOBluetoothDevice) -> Bool {
        let sel = NSSelectorFromString("remove")
        guard device.responds(to: sel) else { return false }
        _ = device.perform(sel)
        return true
    }

    /// Les 6 octets du code forment un entier 64 bits petit-boutiste (deux octets de poids fort nuls).
    static func key(from bytes: [UInt8]) -> UInt64 {
        var key: UInt64 = 0
        for (i, b) in bytes.prefix(8).enumerated() { key |= UInt64(b) << (8 * UInt64(i)) }
        return key
    }

    static func classicPeer(of device: IOBluetoothDevice) -> AnyObject? {
        let sel = NSSelectorFromString("classicPeer")
        guard device.responds(to: sel) else { return nil }
        return device.perform(sel)?.takeUnretainedValue()
    }

    private static func coordinator() -> NSObject? {
        let sel = NSSelectorFromString("sharedInstance")
        guard let cls = NSClassFromString("IOBluetoothCoreBluetoothCoordinator"),
              let method = class_getClassMethod(cls, sel) else { return nil }
        typealias SharedFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: SharedFn.self)(cls, sel)?.takeUnretainedValue() as? NSObject
    }

    /// Envoie le code à bluetoothd pour ce pair et ce type d’appairage.
    static func pairPeer(_ peer: AnyObject, type: UInt, key: UInt64) -> Bool {
        let sel = NSSelectorFromString("pairPeer:forType:withKey:")
        guard let coordinator = coordinator(), coordinator.responds(to: sel) else { return false }
        typealias PairFn = @convention(c) (AnyObject, Selector, AnyObject, UInt, NSNumber) -> Void
        unsafeBitCast(coordinator.method(for: sel), to: PairFn.self)(coordinator, sel, peer, type, NSNumber(value: key))
        return true
    }

    /// Envoie le code octet par octet. Renvoie false si l’API interne n’est pas disponible.
    static func replyBinaryPIN(_ pair: IOBluetoothDevicePair, device: IOBluetoothDevice, bytes: [UInt8]) -> Bool {
        let typeSel = NSSelectorFromString("currentPairingType")
        guard pair.responds(to: typeSel), let peer = classicPeer(of: device) else { return false }
        typealias TypeFn = @convention(c) (AnyObject, Selector) -> UInt
        let type = unsafeBitCast(pair.method(for: typeSel), to: TypeFn.self)(pair, typeSel)
        return pairPeer(peer, type: type, key: key(from: bytes))
    }

    // MARK: - Demandes « sans code » (type 0) de macOS 26

    /// Sur certaines versions de macOS 26, bluetoothd présente l’appairage d’une manette Nintendo
    /// comme une association sans code (type 0) : devicePairingPINCodeRequest n’est jamais appelé
    /// et l’appairage échoue. Comme dolphin-emu/WiimotePair#20, on place temporairement un relais
    /// devant le délégué de l’agent d’appairage Classic : il répond aux demandes de type 0 de notre
    /// manette avec le code binaire (type 6) et transmet tout le reste au délégué d’origine.
    static func installLegacyPINProxy(for device: IOBluetoothDevice, key: UInt64) -> LegacyPINProxy? {
        guard let coordinator = coordinator(), let peer = classicPeer(of: device) else { return nil }
        let managerSel = NSSelectorFromString("classicManager")
        let agentSel = NSSelectorFromString("sharedPairingAgent")
        let delegateSel = NSSelectorFromString("delegate")
        let setDelegateSel = NSSelectorFromString("setDelegate:")
        guard coordinator.responds(to: managerSel),
              let manager = coordinator.perform(managerSel)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: agentSel),
              let agent = manager.perform(agentSel)?.takeUnretainedValue() as? NSObject,
              agent.responds(to: delegateSel), agent.responds(to: setDelegateSel),
              let original = agent.perform(delegateSel)?.takeUnretainedValue() as? NSObject else { return nil }
        let proxy = LegacyPINProxy(agent: agent, original: original, targetPeer: peer, key: key)
        agent.perform(setDelegateSel, with: proxy)
        return proxy
    }
}

final class LegacyPINProxy: NSObject {
    private static let requestSel = NSSelectorFromString("pairingAgent:peerDidRequestPairing:type:passkey:")

    let agent: NSObject
    let original: NSObject
    private let targetPeer: AnyObject
    private let key: UInt64
    private var active = true
    var onReply: (() -> Void)?

    init(agent: NSObject, original: NSObject, targetPeer: AnyObject, key: UInt64) {
        self.agent = agent
        self.original = original
        self.targetPeer = targetPeer
        self.key = key
    }

    /// Remet le délégué d’origine (si personne ne l’a remplacé entre-temps).
    func restore() {
        active = false
        let delegateSel = NSSelectorFromString("delegate")
        if agent.perform(delegateSel)?.takeUnretainedValue() === self {
            agent.perform(NSSelectorFromString("setDelegate:"), with: original)
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

    @objc(pairingAgent:peerDidRequestPairing:type:passkey:)
    func pairingAgent(_ agent: AnyObject?, peerDidRequestPairing peer: AnyObject?, type: Int, passkey: AnyObject?) {
        if active, type == 0, let peer, matches(peer),
           PrivatePairing.pairPeer(peer, type: PrivatePairing.legacyPINType, key: key) {
            onReply?()
            return
        }
        guard original.responds(to: Self.requestSel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, Int, AnyObject?) -> Void
        unsafeBitCast(original.method(for: Self.requestSel), to: Fn.self)(original, Self.requestSel, agent, peer, type, passkey)
    }

    private func matches(_ peer: AnyObject) -> Bool {
        if peer === targetPeer { return true }
        let idSel = NSSelectorFromString("identifier")
        guard let p = peer as? NSObject, let t = targetPeer as? NSObject,
              p.responds(to: idSel), t.responds(to: idSel),
              let a = p.perform(idSel)?.takeUnretainedValue() as? NSObject else { return false }
        return a.isEqual(t.perform(idSel)?.takeUnretainedValue())
    }
}
