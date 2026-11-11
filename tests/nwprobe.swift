// nwprobe <host> <port> [wifi|wired] — TCP-подключение через Network.framework (как Safari/URLSession).
// Печатает READY/FAILED/WAITING/TIMEOUT. С "wifi"/"wired" — принудительно через Wi-Fi/Ethernet в обход туннеля.
import Foundation
import Network

let args = CommandLine.arguments
guard args.count >= 3, let p = UInt16(args[2]), let port = NWEndpoint.Port(rawValue: p) else {
    print("usage: nwprobe <host> <port> [wifi|wired]"); exit(64)
}
let params = NWParameters.tcp
if args.count > 3 && args[3] == "wifi" { params.requiredInterfaceType = .wifi }
if args.count > 3 && args[3] == "wired" { params.requiredInterfaceType = .wiredEthernet }
let conn = NWConnection(host: NWEndpoint.Host(args[1]), port: port, using: params)
let start = Date()
func elapsed() -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }
conn.stateUpdateHandler = { st in
    switch st {
    case .ready:
        let ifname = conn.currentPath?.availableInterfaces.first?.name ?? "?"
        print("READY via \(ifname) \(elapsed())"); exit(0)
    case .failed(let e): print("FAILED \(e) \(elapsed())"); exit(2)
    case .waiting(let e): print("WAITING \(e) \(elapsed())"); exit(3)
    default: break
    }
}
conn.start(queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + 6) { print("TIMEOUT \(elapsed())"); exit(4) }
dispatchMain()
