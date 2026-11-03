import AppKit
import CryptoKit
import Network
import TotemCore

/// Google Drive sync for the Mac app. Same layout as the extension (same Google Cloud project →
/// both see the same files with the drive.file scope):
///   /Totem Authenticator/totem-vault.json   and   /Totem Authenticator/backups/totem-backup-*.json
/// Sign-in: OAuth "Desktop app" client, PKCE, loopback redirect on 127.0.0.1. Refresh token → Keychain.
final class GoogleDrive {
    static let shared = GoogleDrive()
    private let scope = "https://www.googleapis.com/auth/drive.file"
    private let api = "https://www.googleapis.com/drive/v3"
    private let upload = "https://www.googleapis.com/upload/drive/v3"
    private let folderName = "Totem Authenticator"
    private let liveName = "totem-vault.json"
    private let keepBackups = 30
    private var accessToken: (value: String, expires: Date)?

    var clientId: String { UserDefaults.standard.string(forKey: "driveClientId") ?? "" }
    var clientSecret: String { UserDefaults.standard.string(forKey: "driveClientSecret") ?? "" }
    var isConnected: Bool { Keychain.get("drive.refresh") != nil }

    enum DriveError: LocalizedError {
        case notConfigured, notConnected, http(Int, String), auth(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Add your Google OAuth client ID and secret in Settings first"
            case .notConnected: return "Google Drive isn't connected"
            case .http(let c, let b): return "Google Drive error \(c): \(b.prefix(160))"
            case .auth(let m): return "Google sign-in: \(m)"
            }
        }
    }

    // MARK: sign-in

    func connect() async throws {
        guard !clientId.isEmpty, !clientSecret.isEmpty else { throw DriveError.notConfigured }
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)
        let receiver = try LoopbackReceiver()
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientId), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"), .init(name: "state", value: state),
        ]
        let authURL = c.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }
        let params = try await receiver.waitForCallback()
        guard params["state"] == state else { throw DriveError.auth("state mismatch") }
        if let err = params["error"] { throw DriveError.auth(err) }
        guard let code = params["code"] else { throw DriveError.auth("no code returned") }
        let tok = try await tokenRequest(["code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect])
        guard let refresh = tok["refresh_token"] as? String else { throw DriveError.auth("no refresh token — remove Totem's access at myaccount.google.com/permissions and try again") }
        Keychain.set(Data(refresh.utf8), for: "drive.refresh")
        store(tok)
    }

    func disconnect() {
        if let r = Keychain.get("drive.refresh"), let t = String(data: r, encoding: .utf8) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.delete("drive.refresh")
        accessToken = nil
    }

    private func tokenRequest(_ extra: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = extra
        all["client_id"] = clientId
        all["client_secret"] = clientSecret
        req.httpBody = all.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, res) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw DriveError.auth(json["error_description"] as? String ?? json["error"] as? String ?? "token request failed")
        }
        return json
    }

    private func store(_ tok: [String: Any]) {
        if let v = tok["access_token"] as? String {
            accessToken = (v, Date().addingTimeInterval(Double(tok["expires_in"] as? Int ?? 3600) - 60))
        }
    }

    private func token() async throws -> String {
        if let t = accessToken, t.expires > Date() { return t.value }
        guard let r = Keychain.get("drive.refresh"), let refresh = String(data: r, encoding: .utf8) else { throw DriveError.notConnected }
        store(try await tokenRequest(["refresh_token": refresh, "grant_type": "refresh_token"]))
        guard let t = accessToken else { throw DriveError.notConnected }
        return t.value
    }

    // MARK: REST

    private func call(_ path: String, method: String = "GET", base: String? = nil, body: Data? = nil,
                      contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: (base ?? api) + path)!)
        req.httpMethod = method
        let bearer = try await token()
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        let (data, res) = try await URLSession.shared.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { accessToken = nil }
        guard (200..<300).contains(code) else { throw DriveError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    private func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
    private func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }

    private func find(_ name: String, parent: String?, folder: Bool = false) async throws -> String? {
        var q = ["name='\(esc(name))'", "trashed=false"]
        if let parent { q.append("'\(parent)' in parents") }
        if folder { q.append("mimeType='application/vnd.google-apps.folder'") }
        let query = q.joined(separator: " and ").urlQueryEncoded
        let r = json(try await call("/files?spaces=drive&fields=files(id)&q=\(query)"))
        return ((r["files"] as? [[String: Any]])?.first?["id"]) as? String
    }

    private func ensureFolder(_ name: String, parent: String?) async throws -> String {
        if let id = try await find(name, parent: parent, folder: true) { return id }
        var meta: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        if let parent { meta["parents"] = [parent] }
        let r = json(try await call("/files?fields=id", method: "POST", body: try JSONSerialization.data(withJSONObject: meta),
                                    contentType: "application/json"))
        return r["id"] as? String ?? ""
    }

    private func folders() async throws -> (root: String, backups: String) {
        let root = try await ensureFolder(folderName, parent: nil)
        return (root, try await ensureFolder("backups", parent: root))
    }

    private func create(_ name: String, parent: String, content: Data) async throws {
        let boundary = "totem\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent], "mimeType": "application/json"])
        body += Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8)
        body += content
        body += Data("\r\n--\(boundary)--".utf8)
        _ = try await call("/files?uploadType=multipart&fields=id", method: "POST", base: upload, body: body,
                           contentType: "multipart/related; boundary=\(boundary)")
    }

    private func update(_ id: String, content: Data) async throws {
        _ = try await call("/files/\(id)?uploadType=media", method: "PATCH", base: upload, body: content, contentType: "application/json")
    }

    func pull() async throws -> Envelope? {
        let f = try await folders()
        guard let id = try await find(liveName, parent: f.root) else { return nil }
        return try Vault.decodeEnvelope(try await call("/files/\(id)?alt=media"))
    }

    func push(_ env: Envelope, forceBackup: Bool = false) async throws {
        let f = try await folders()
        let content = try Vault.encodeEnvelope(env)
        if let id = try await find(liveName, parent: f.root) { try await update(id, content: content) }
        else { try await create(liveName, parent: f.root, content: content) }

        let iso = ISO8601DateFormatter().string(from: Date())
        let name = forceBackup
            ? "totem-backup-\(iso.replacingOccurrences(of: ":", with: "-").prefix(19)).json"
            : "totem-backup-\(iso.prefix(10)).json"
        if let id = try await find(name, parent: f.backups) { try await update(id, content: content) }
        else { try await create(name, parent: f.backups, content: content) }

        let q = "'\(f.backups)' in parents and trashed=false".urlQueryEncoded
        let list = json(try await call("/files?spaces=drive&orderBy=createdTime%20desc&pageSize=200&fields=files(id)&q=\(q)"))
        for item in (list["files"] as? [[String: Any]] ?? []).dropFirst(keepBackups) {
            if let id = item["id"] as? String { _ = try? await call("/files/\(id)", method: "DELETE") }
        }
    }

    func backups() async throws -> [BackupItem] {
        let f = try await folders()
        let q = "'\(f.backups)' in parents and trashed=false".urlQueryEncoded
        let r = json(try await call("/files?spaces=drive&orderBy=createdTime%20desc&pageSize=50&fields=files(id,name,createdTime)&q=\(q)"))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (r["files"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return BackupItem(id: id, name: $0["name"] as? String ?? "", created: fmt.date(from: $0["createdTime"] as? String ?? "") ?? Date())
        }
    }

    func download(_ id: String) async throws -> Envelope {
        try Vault.decodeEnvelope(try await call("/files/\(id)?alt=media"))
    }

    static func randomURLSafe(_ n: Int) -> String { Vault.randomBytes(n).base64URL }
}

// MARK: - one-shot loopback HTTP receiver for the OAuth redirect

final class LoopbackReceiver {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            final class Once { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let e): once.done = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global())
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(.failure(GoogleDrive.DriveError.auth("timed out")))
            }
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        listener.cancel()
        c.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let req = String(decoding: data ?? Data(), as: UTF8.self)
            let line = req.split(separator: "\r\n").first ?? ""
            let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            var params: [String: String] = [:]
            for i in items { params[i.name] = i.value ?? "" }
            let html = """
            <!doctype html><meta charset="utf-8"><title>Totem</title>
            <body style="font:16px -apple-system;display:grid;place-items:center;height:90vh;background:#0b0f16;color:#e9eef6">
            <div><h2>\(params["error"] == nil ? "Google Drive connected ✓" : "Sign-in was cancelled")</h2>
            <p style="color:#8b98ad">You can close this tab and go back to Totem.</p></div>
            """
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if params["code"] != nil || params["error"] != nil { self?.finish(.success(params)) }
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
    var urlQueryEncoded: String { formEncoded }
}
