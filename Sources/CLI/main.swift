import Foundation

let usage = """
Usage : wiiu-pro-dsu [--address 8C:CD:E8:BB:0D:58] [--port 26760] [--verbose] [--demo]

  --address  adresse Bluetooth de la manette (sinon : recherche, appuyez sur SYNC)
  --port     port UDP du serveur DSU sur 127.0.0.1 (défaut 26760)
  --verbose  affiche les paquets échangés et les mouvements des sticks
  --demo     sans Bluetooth : manette simulée (A appuyé une seconde sur deux, stick gauche en cercle)
"""

var address: String?
var port: UInt16 = 26760
var verbose = false
var demo = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--address": address = args.next()
    case "--port": port = args.next().flatMap(UInt16.init) ?? port
    case "--verbose", "-v": verbose = true
    case "--demo": demo = true
    case "--help", "-h": print(usage); exit(0)
    default: print("Option inconnue : \(arg)\n\n\(usage)"); exit(2)
    }
}

let bridge = Bridge()
bridge.verbose = verbose
do {
    try bridge.listen(port: port)
} catch {
    log("Impossible de démarrer le serveur DSU : \(error.localizedDescription)")
    exit(1)
}
bridge.start(address: address, demo: demo)
RunLoop.main.run()
