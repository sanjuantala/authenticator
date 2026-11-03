// TotemBridge — Chrome native-messaging host.
// Chrome starts this for each message from the Totem extension (only that extension ID is allowed,
// see the host manifest). It relays the message to the running Totem app over a user-only Unix socket.
// If the app isn't running it can still read/write the *encrypted* vault file, so sync keeps working.
import Foundation

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Totem", isDirectory: true)
let socketPath = supportDir.appendingPathComponent("bridge.sock").path
let vaultURL = supportDir.appendingPathComponent("vault.json")

// MARK: native messaging framing (4-byte little-endian length + UTF-8 JSON)

func readMessage() -> Data? {
    let stdin = FileHandle.standardInput
    let header = stdin.readData(ofLength: 4)
    guard header.count == 4 else { return nil }
    let len = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    guard len > 0, len < 16 * 1024 * 1024 else { return nil }
    var body = Data()
    while body.count < Int(len) {
        let chunk = stdin.readData(ofLength: Int(len) - body.count)
        if chunk.isEmpty { return nil }
        body.append(chunk)
    }
    return body
}

func writeMessage(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var len = UInt32(data.count).littleEndian
    let out = FileHandle.standardOutput
    out.write(Data(bytes: &len, count: 4))
    out.write(data)
}

// MARK: socket to the app

func askApp(_ payload: Data) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard socketPath.utf8.count < maxLen else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: maxLen) { _ = strncpy($0, socketPath, maxLen - 1) }
    }
    var tv = timeval(tv_sec: 90, tv_usec: 0) // long enough for a Touch ID prompt
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return nil }
    var msg = payload
    msg.append(0x0A)
    let sent = msg.withUnsafeBytes { buf -> Bool in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    guard sent else { return nil }
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        response.append(contentsOf: buf[0..<n])
        if response.last == 0x0A { break }
    }
    return response.isEmpty ? nil : response
}

// MARK: offline fallback (app not running): encrypted file only, never decrypts

func readVault() -> [String: Any]? {
    guard let d = try? Data(contentsOf: vaultURL) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func offline(_ req: [String: Any]) -> [String: Any] {
    switch req["type"] as? String {
    case "status":
        return ["ok": true, "running": false, "unlocked": false, "hasVault": readVault() != nil]
    case "getVault":
        return ["ok": true, "vault": readVault() ?? NSNull(), "running": false]
    case "putVault":
        guard let incoming = req["vault"] as? [String: Any], incoming["format"] as? String == "totem-vault" else {
            return ["ok": false, "error": "Not a Totem vault"]
        }
        let current = readVault()
        let base = number(req["base"])
        let force = req["force"] as? Bool ?? false
        if current != nil && !force && base != number(current?["updatedAt"]) {
            return ["ok": false, "error": "The Mac vault changed meanwhile — sync again", "code": "CONFLICT"]
        }
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: incoming, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: vaultURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
            return ["ok": true]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    case "requestKey":
        return ["ok": false, "error": "Open Totem for Mac first, then try again", "code": "APP_NOT_RUNNING"]
    default:
        return ["ok": false, "error": "Unknown request"]
    }
}

// MARK: main

guard let body = readMessage() else { exit(0) }
if let reply = askApp(body), let obj = try? JSONSerialization.jsonObject(with: reply) {
    writeMessage(obj)
} else if let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
    writeMessage(offline(req))
} else {
    writeMessage(["ok": false, "error": "Bad request"])
}
