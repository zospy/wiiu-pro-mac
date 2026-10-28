import Foundation
import IOKit.hid

/// Signale les manettes Nintendo que macOS présente en HID (après appairage, macOS ouvre lui-même
/// les canaux Bluetooth HID). Les manettes déjà connectées sont signalées dès le démarrage.
final class HIDWatcher {
    static let nintendoVendorID = 0x057E
    static let productIDs: Set<Int> = [0x0330, 0x0306]  // Wii U Pro, Wiimote

    var onAppear: ((IOHIDDevice) -> Void)?
    var onRemove: ((IOHIDDevice) -> Void)?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func start() {
        let matches = Self.productIDs.map {
            [kIOHIDVendorIDKey: Self.nintendoVendorID, kIOHIDProductIDKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().onAppear?(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().onRemove?(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { log("Surveillance HID impossible : \(hex(r)).") }
    }

    func stop() {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

/// Lien vers une manette ouverte par la couche HID de macOS : IOHIDDeviceSetReport pour les envois
/// (bluetoothd les transmet sur le canal Interrupt, en-tête 0xA2) et un rappel pour les rapports reçus.
final class HIDLink {
    var onReport: (([UInt8]) -> Void)?
    var onRemoved: (() -> Void)?

    let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var closed = false

    init?(device: IOHIDDevice) {
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            log("Ouverture HID de la manette refusée : \(hex(r)).")
            buffer.deallocate()
            return nil
        }
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let link = Unmanaged<HIDLink>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Le rapport commence normalement par son identifiant ; sinon on le rajoute.
            if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            link.onReport?(bytes)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<HIDLink>.fromOpaque(context).takeUnretainedValue().onRemoved?()
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    var name: String { IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?" }
    var serial: String? { IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String }

    /// `payload` commence par l’identifiant du rapport de sortie (0x11, 0x12, 0x16…).
    @discardableResult
    func send(_ payload: [UInt8]) -> IOReturn {
        guard !closed, let id = payload.first else { return kIOReturnNotOpen }
        return payload.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), $0.baseAddress!, $0.count)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        close()
        buffer.deallocate()
    }
}
