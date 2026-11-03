import Foundation
import Security

/// Listens on ~/Library/Application Support/Totem/bridge.sock (mode 0600, same-user peers only).
/// TotemBridge connects here on behalf of the browser extension. One JSON line in, one JSON line out.
final class BridgeServer {
    private var fd: Int32 = -1
    private let handler: (Data) async -> Data

    init(handler: @escaping (Data) async -> Data) { self.handler = handler }

    func start() {
        let path = Paths.socket.path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { NSLog("Totem: socket path too long"); return }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxLen) { _ = strncpy($0, path, maxLen - 1) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { NSLog("Totem: bind failed \(errno)"); close(fd); return }
        chmod(path, 0o600)
        listen(fd, 16)
        let listenFD = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listenFD, nil, nil)
                if c < 0 { if errno == EBADF { return }; continue }
                // only processes running as this macOS user may talk to us…
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
                // …and only the genuine, untampered TotemBridge that ships inside this app
                guard BridgeServer.peerIsOurBridge(c) else { NSLog("Totem: rejected a connection from an unknown program"); close(c); continue }
                self?.serve(c)
            }
        }
    }

    /// Checks the connecting process: its code signature must be valid and it must be the TotemBridge
    /// file next to this app's executable. Other programs (even running as you) are turned away.
    static func peerIsOurBridge(_ fd: Int32) -> Bool {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &len) == 0, pid > 0 else { return false }
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let path = (url as URL?)?.resolvingSymlinksInPath().path else { return false }
        let expected = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("TotemBridge")
            .resolvingSymlinksInPath().path
        return path == expected
    }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(Paths.socket.path)
    }

    private func serve(_ c: Int32) {
        DispatchQueue.global().async { [handler] in
            var line = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while line.count < 8 * 1024 * 1024 {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                line.append(contentsOf: buf[0..<n])
                if line.last == 0x0A { break }
            }
            let request = line
            Task {
                var reply = await handler(request)
                reply.append(0x0A)
                reply.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(c, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { break }
                        off += n
                    }
                }
                close(c)
            }
        }
    }
}
