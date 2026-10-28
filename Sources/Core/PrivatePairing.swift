import Foundation
import IOBluetooth

/// Appairage avec un code binaire, comme l’outil officiel de Dolphin (dolphin-emu/WiimotePair).
///
/// `IOBluetoothDevicePair.replyPINCode` convertit le code en texte avant de l’envoyer à bluetoothd,
/// ce qui abîme les octets ≥ 0x80 du code des manettes Nintendo. On appelle donc directement
/// la méthode interne que replyPINCode utilise : `IOBluetoothCoreBluetoothCoordinator
/// pairPeer:forType:withKey:`. Ces API sont privées : chaque appel vérifie d’abord qu’elles existent.
enum PrivatePairing {
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

    /// Envoie le code octet par octet. Renvoie false si l’API interne n’est pas disponible.
    static func replyBinaryPIN(_ pair: IOBluetoothDevicePair, device: IOBluetoothDevice, bytes: [UInt8]) -> Bool {
        let sharedSel = NSSelectorFromString("sharedInstance")
        let peerSel = NSSelectorFromString("classicPeer")
        let typeSel = NSSelectorFromString("currentPairingType")
        let pairSel = NSSelectorFromString("pairPeer:forType:withKey:")

        guard let coordinatorClass = NSClassFromString("IOBluetoothCoreBluetoothCoordinator"),
              let sharedMethod = class_getClassMethod(coordinatorClass, sharedSel),
              device.responds(to: peerSel), pair.responds(to: typeSel) else { return false }

        typealias SharedFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        guard let coordinator = unsafeBitCast(method_getImplementation(sharedMethod), to: SharedFn.self)(coordinatorClass, sharedSel)?
                .takeUnretainedValue() as? NSObject,
              coordinator.responds(to: pairSel),
              let peer = device.perform(peerSel)?.takeUnretainedValue() else { return false }

        typealias TypeFn = @convention(c) (AnyObject, Selector) -> UInt
        let type = unsafeBitCast(pair.method(for: typeSel), to: TypeFn.self)(pair, typeSel)

        // Les 6 octets du code forment un entier 64 bits petit-boutiste (deux octets de poids fort nuls).
        var key: UInt64 = 0
        for (i, b) in bytes.prefix(8).enumerated() { key |= UInt64(b) << (8 * UInt64(i)) }

        typealias PairFn = @convention(c) (AnyObject, Selector, AnyObject, UInt, NSNumber) -> Void
        unsafeBitCast(coordinator.method(for: pairSel), to: PairFn.self)(coordinator, pairSel, peer, type, NSNumber(value: key))
        return true
    }
}
