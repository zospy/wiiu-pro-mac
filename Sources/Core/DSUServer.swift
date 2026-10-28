import Foundation
import Darwin

/// Serveur DSU (protocole « cemuhook », version 1001) lu par le client DSU de Dolphin.
/// Un seul emplacement (0) est exposé, avec une disposition de manette DualShock 4.
final class DSUServer {
    struct Pad {
        var buttons1: UInt8 = 0  // gauche 0x80, bas 0x40, droite 0x20, haut 0x10, Options 0x08, R3 0x04, L3 0x02, Share 0x01
        var buttons2: UInt8 = 0  // Carré 0x80, Croix 0x40, Rond 0x20, Triangle 0x10, R1 0x08, L1 0x04, R2 0x02, L2 0x01
        var ps: UInt8 = 0
        var lx: UInt8 = 128, ly: UInt8 = 128, rx: UInt8 = 128, ry: UInt8 = 128
    }

    static let protocolVersion: UInt16 = 1001
    static let msgVersion: UInt32 = 0x100000
    static let msgPorts: UInt32 = 0x100001
    static let msgPadData: UInt32 = 0x100002
    static let clientTimeout: TimeInterval = 5

    var pad = Pad()
    var connected = false
    var mac: [UInt8] = [0, 0, 0, 0, 0, 0]
    var verbose = false

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [String: (address: sockaddr_in, lastSeen: Date)] = [:]
    private let serverID = UInt32.random(in: 0...UInt32.max)
    private var packetNumber: UInt32 = 0
    private let start = Date()

    func listen(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw posixError("socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { throw posixError("bind 127.0.0.1:\(port)") }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.receive() }
        src.resume()
        source = src
    }

    /// Envoie l’état courant à tous les clients abonnés (à appeler à chaque rapport et périodiquement).
    func broadcast() {
        let now = Date()
        clients = clients.filter { now.timeIntervalSince($0.value.lastSeen) < Self.clientTimeout }
        guard connected, !clients.isEmpty else { return }
        let packet = padDataPacket()
        for client in clients.values { sendPacket(packet, to: client.address) }
    }

    // MARK: - Réception

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { buf in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                }
            }
        }
        guard n >= 20 else { return }
        let p = Array(buffer[0..<n])
        guard p[0...3] == [0x44, 0x53, 0x55, 0x43] else { return }  // "DSUC"

        let type = readU32(p, 16)
        switch type {
        case Self.msgVersion:
            var body: [UInt8] = []
            appendU16(&body, Self.protocolVersion)
            sendPacket(packet(type: Self.msgVersion, body: body), to: from)
        case Self.msgPorts where n >= 24:
            let count = min(Int(readU32(p, 20)), 4, n - 24)
            for i in 0..<max(count, 0) {
                let slot = p[24 + i]
                sendPacket(packet(type: Self.msgPorts, body: sharedHeader(slot: slot) + [0]), to: from)
            }
        case Self.msgPadData:
            let key = "\(from.sin_addr.s_addr):\(from.sin_port)"
            if clients[key] == nil && verbose { log("DSU : nouveau client abonné (\(key))") }
            clients[key] = (from, Date())
            if connected { sendPacket(padDataPacket(), to: from) }
        default:
            break
        }
    }

    // MARK: - Construction des paquets

    private func sharedHeader(slot: UInt8) -> [UInt8] {
        guard slot == 0, connected else {
            return [slot, 0, 0, 0] + [UInt8](repeating: 0, count: 7)
        }
        // emplacement, état=connecté, modèle=DS4 complet, connexion=Bluetooth, MAC, batterie=pleine
        return [slot, 2, 2, 2] + mac + [0x05]
    }

    private func padDataPacket() -> [UInt8] {
        packetNumber &+= 1
        var body = sharedHeader(slot: 0)
        body.append(1)
        appendU32(&body, packetNumber)
        body += [pad.buttons1, pad.buttons2, pad.ps, 0, pad.lx, pad.ly, pad.rx, pad.ry]
        // pressions analogiques : gauche, bas, droite, haut, Carré, Croix, Rond, Triangle, R1, L1, R2, L2
        let b1 = pad.buttons1, b2 = pad.buttons2
        for (byte, mask) in [(b1, 0x80), (b1, 0x40), (b1, 0x20), (b1, 0x10),
                             (b2, 0x80), (b2, 0x40), (b2, 0x20), (b2, 0x10),
                             (b2, 0x08), (b2, 0x04), (b2, 0x02), (b2, 0x01)] as [(UInt8, UInt8)] {
            body.append(byte & mask != 0 ? 0xFF : 0)
        }
        body += [UInt8](repeating: 0, count: 12)  // deux points tactiles inactifs
        let micros = UInt64(Date().timeIntervalSince(start) * 1_000_000)
        for i in 0..<8 { body.append(UInt8((micros >> (8 * UInt64(i))) & 0xFF)) }
        body += [UInt8](repeating: 0, count: 24)  // accéléromètre et gyroscope absents
        return packet(type: Self.msgPadData, body: body)
    }

    private func packet(type: UInt32, body: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x44, 0x53, 0x55, 0x53]  // "DSUS"
        appendU16(&p, Self.protocolVersion)
        appendU16(&p, UInt16(4 + body.count))
        appendU32(&p, 0)  // CRC32, calculé plus bas
        appendU32(&p, serverID)
        appendU32(&p, type)
        p += body
        let crc = crc32(p)
        for i in 0..<4 { p[8 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
        return p
    }

    private func sendPacket(_ p: [UInt8], to address: sockaddr_in) {
        var addr = address
        _ = p.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

private func appendU16(_ a: inout [UInt8], _ v: UInt16) { a += [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func appendU32(_ a: inout [UInt8], _ v: UInt32) { for i in 0..<4 { a.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
private func readU32(_ a: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(a[o + $1]) << (8 * UInt32($1)) } }

private func posixError(_ what: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what) : \(String(cString: strerror(errno)))"])
}
