import Foundation
import CryptoKit
import Network
import AppKit

// OAuth config

enum OAuthConfig {
    // Public OAuth client ID shared with Claude Code — not a secret (PKCE flow, no client secret)
    static let clientId       = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL   = "https://claude.com/cai/oauth/authorize"
    static let tokenURL       = "https://platform.claude.com/v1/oauth/token"
    static let redirectURI    = "http://localhost"
    static let scopes         = ["user:inference", "user:profile"]
    static let betaHeader     = "oauth-2025-04-20"
}

struct OAuthCredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let lastRefreshed: Date?  // persisted so we don't re-refresh on every app launch

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() >= exp.addingTimeInterval(-60)
    }

    init(accessToken: String, refreshToken: String?, expiresAt: Date?, lastRefreshed: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.lastRefreshed = lastRefreshed
    }
}

// Credential storage
// Stores tokens in ~/Library/Application Support/Quota/ with 600 perms.

enum CredentialStore {
    private static var credentialFile: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Quota", isDirectory: true)
        // Ensure directory exists with restricted permissions
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        return dir.appendingPathComponent("credentials.dat")
    }

    static func save(_ creds: OAuthCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let url = credentialFile
        // Atomic write: write to temp file first, then rename
        // Prevents corruption if app crashes mid-write
        let tmpURL = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmpURL.path, contents: data, attributes: [
            .posixPermissions: 0o600
        ])
        do {
            // Remove existing then move temp → final
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmpURL, to: url)
        } catch {
            // Fallback: direct write
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [
                .posixPermissions: 0o600
            ])
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    static func load() -> OAuthCredentials? {
        let url = credentialFile
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: credentialFile)
    }
}

enum PKCE {
    static func generate() -> (verifier: String, challenge: String) {
        let verifier = generateVerifier()
        return (verifier, sha256Base64URL(verifier))
    }

    private static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func sha256Base64URL(_ input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// Local callback server
// Ephemeral TCP listener on loopback. Accepts exactly one auth callback, then shuts down.

final class OAuthCallbackServer: @unchecked Sendable {
    private var listener: NWListener?
    var onCallbackReceived: ((_ code: String, _ state: String?) -> Void)?
    private(set) var port: UInt16 = 0
    private var didReceiveCode = false  // Guard against duplicate callbacks

    func start() throws -> UInt16 {
        // Retry up to 3 times if port binding fails
        var lastError: Error?
        for _ in 0..<3 {
            do {
                let p = try attemptStart()
                return p
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError ?? OAuthError.invalidURL
    }

    private func attemptStart() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params, on: .any)

        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener?.port?.rawValue ?? 0
                sem.signal()
            case .failed(let error):
                startError = error
                sem.signal()
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] in self?.handleConnection($0) }
        listener?.start(queue: .global(qos: .userInitiated))

        // Wait with 5s timeout to prevent deadlock
        let result = sem.wait(timeout: .now() + 5)
        if result == .timedOut {
            listener?.cancel()
            listener = nil
            throw OAuthError.timeout
        }
        if let error = startError {
            listener?.cancel()
            listener = nil
            throw error
        }
        return port
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            defer { conn.cancel() }
            guard let self = self, !self.didReceiveCode else { return }
            guard let data = data, let req = String(data: data, encoding: .utf8) else { return }

            // Handle favicon and other non-callback requests gracefully
            guard let params = self.extractCallbackParams(from: req),
                  let code = params.code else {
                // Respond with empty 204 for non-callback requests (favicon, etc.)
                let notFound = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                conn.send(content: notFound.data(using: .utf8)!, completion: .contentProcessed { _ in })
                return
            }

            // Mark as received — prevent duplicate processing
            self.didReceiveCode = true

            let html = Self.successPageHTML
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
            conn.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in })
            self.onCallbackReceived?(code, params.state)

            // Delay stop slightly to ensure response is sent
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                self.stop()
            }
        }
    }

    private func extractCallbackParams(from request: String) -> (code: String?, state: String?)? {
        guard let line = request.components(separatedBy: "\r\n").first,
              let path = line.components(separatedBy: " ").dropFirst().first,
              path.contains("/callback"),
              let url = URL(string: "http://127.0.0.1\(path)"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let code  = comps.queryItems?.first(where: { $0.name == "code" })?.value
        let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // Callback success page

    private static let successPageHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Quota \u{2014} Connected</title>
    <style>
      *{margin:0;padding:0;box-sizing:border-box}
      :root{--amber:#d4a96a;--amber-glow:rgba(212,169,106,0.15);--bg:#0a0a0b;--card:#141416;--border:#1f1f23;--text:#e8e8ea;--muted:#6b6b70}
      body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','SF Pro Text',system-ui,sans-serif;
           display:flex;justify-content:center;align-items:center;min-height:100vh;
           background:var(--bg);color:var(--text);overflow:hidden}

      /* Ambient glow behind card */
      .ambient{position:fixed;width:500px;height:500px;border-radius:50%;
               background:radial-gradient(circle,var(--amber-glow) 0%,transparent 70%);
               top:50%;left:50%;transform:translate(-50%,-50%);
               animation:pulse 4s ease-in-out infinite;pointer-events:none;z-index:0}
      @keyframes pulse{0%,100%{opacity:0.4;scale:1}50%{opacity:0.7;scale:1.1}}

      .card{position:relative;z-index:1;text-align:center;padding:52px 48px 44px;border-radius:24px;
            background:var(--card);border:1px solid var(--border);max-width:400px;width:90%;
            box-shadow:0 0 0 1px rgba(255,255,255,0.03),0 24px 80px rgba(0,0,0,0.5);
            animation:cardIn 0.6s cubic-bezier(0.16,1,0.3,1) both;
            backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px)}
      @keyframes cardIn{from{opacity:0;transform:translateY(20px) scale(0.97)}to{opacity:1;transform:none}}

      /* Gauge ring animation */
      .gauge-wrap{position:relative;width:88px;height:88px;margin:0 auto 28px}
      .gauge-ring{width:88px;height:88px;transform:rotate(-90deg)}
      .gauge-track{fill:none;stroke:#1f1f23;stroke-width:4}
      .gauge-fill{fill:none;stroke:var(--amber);stroke-width:4;stroke-linecap:round;
                   stroke-dasharray:245;stroke-dashoffset:245;
                   animation:ringFill 1.4s cubic-bezier(0.33,1,0.68,1) 0.3s forwards;
                   filter:drop-shadow(0 0 6px var(--amber-glow))}
      @keyframes ringFill{to{stroke-dashoffset:0}}

      .gauge-check{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);
                    font-size:32px;opacity:0;animation:checkPop 0.4s cubic-bezier(0.34,1.56,0.64,1) 1.2s forwards}
      @keyframes checkPop{from{opacity:0;scale:0.3}to{opacity:1;scale:1}}

      h1{font-size:22px;font-weight:600;color:var(--amber);margin-bottom:10px;letter-spacing:-0.3px;
         opacity:0;animation:fadeUp 0.5s ease 0.8s forwards}
      .subtitle{color:var(--muted);font-size:14px;line-height:1.6;
                opacity:0;animation:fadeUp 0.5s ease 1s forwards}
      @keyframes fadeUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}

      .divider{height:1px;background:var(--border);margin:28px 0 20px;
               opacity:0;animation:fadeUp 0.4s ease 1.2s forwards}

      .hint{display:flex;align-items:center;justify-content:center;gap:6px;
            color:var(--muted);font-size:12px;
            opacity:0;animation:fadeUp 0.4s ease 1.4s forwards}
      .hint .dot{width:6px;height:6px;border-radius:50%;background:#34d399;
                 animation:dotPulse 2s ease-in-out 1.6s infinite}
      @keyframes dotPulse{0%,100%{opacity:1}50%{opacity:0.4}}

      .close-hint{margin-top:16px;color:var(--muted);font-size:11px;opacity:0;
                   animation:fadeUp 0.4s ease 1.8s forwards}
      .close-hint kbd{background:#1f1f23;padding:2px 7px;border-radius:5px;font-family:inherit;
                      font-size:11px;border:1px solid #2a2a2e;color:#999}
    </style>
    </head>
    <body>
      <div class="ambient"></div>
      <div class="card">
        <div class="gauge-wrap">
          <svg class="gauge-ring" viewBox="0 0 88 88">
            <circle class="gauge-track" cx="44" cy="44" r="39"/>
            <circle class="gauge-fill" cx="44" cy="44" r="39"/>
          </svg>
          <div class="gauge-check">\u{2713}</div>
        </div>
        <h1>You&rsquo;re connected</h1>
        <p class="subtitle">Quota is now monitoring your Claude rate limits<br>in real-time from your menu bar.</p>
        <div class="divider"></div>
        <div class="hint">
          <span class="dot"></span>
          <span>Syncing usage data</span>
        </div>
        <p class="close-hint">You can close this tab \u{2014} or press <kbd>\u{2318}W</kbd></p>
      </div>
    </body>
    </html>
    """
}

@MainActor
final class OAuthManager: ObservableObject {
    @Published var isAuthenticating = false
    @Published var error: String?

    private var server: OAuthCallbackServer?
    private var codeVerifier = ""
    private var oauthState = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    func startLogin(completion: @escaping (OAuthCredentials) -> Void) {
        isAuthenticating = true
        error = nil

        Task {
            do {
                let creds = try await performFlow()
                self.isAuthenticating = false
                completion(creds)
            } catch is CancellationError {
                self.isAuthenticating = false
            } catch let loginError {
                self.isAuthenticating = false
                if let oauthErr = loginError as? OAuthError {
                    self.error = oauthErr.errorDescription
                } else {
                    self.error = loginError.localizedDescription
                }
            }
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(throwing: OAuthError.cancelled)
        continuation = nil
        server?.stop()
        server = nil
        isAuthenticating = false
    }

    

    static func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        guard let refreshToken = creds.refreshToken else {
            throw OAuthError.noRefreshToken
        }

        var req = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var formComps = URLComponents()
        formComps.queryItems = [
            URLQueryItem(name: "grant_type",    value: "refresh_token"),
            URLQueryItem(name: "client_id",     value: OAuthConfig.clientId),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        req.httpBody = formComps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = sanitizedError(from: data)
            throw OAuthError.exchangeFailed(msg)
        }
        var newCreds = try parseTokenResponse(data)
        // Preserve the old refresh token if the server didn't send a new one
        // (Anthropic refresh tokens are single-use but the response should include a new one)
        if newCreds.refreshToken == nil {
            newCreds = OAuthCredentials(
                accessToken: newCreds.accessToken,
                refreshToken: creds.refreshToken,
                expiresAt: newCreds.expiresAt
            )
        }
        return newCreds
    }

    

    private func performFlow() async throws -> OAuthCredentials {
        let pkce = PKCE.generate()
        codeVerifier = pkce.verifier
        oauthState = UUID().uuidString

        let srv = OAuthCallbackServer()
        server = srv
        let port = try srv.start()
        let redirectURI = "\(OAuthConfig.redirectURI):\(port)/callback"

        var comps = URLComponents(string: OAuthConfig.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: OAuthConfig.clientId),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "scope",                 value: OAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge",        value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: oauthState),
        ]
        guard let authURL = comps.url else { throw OAuthError.invalidURL }

        NSWorkspace.shared.open(authURL)

        // Wait for the OAuth callback with state validation and cancellable timeout
        let expectedState = oauthState
        let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            // Callback fires from a background queue — hop to MainActor to
            // safely access continuation (prevents double-resume data race)
            srv.onCallbackReceived = { [weak self] code, state in
                Task { @MainActor [weak self] in
                    guard let self, self.continuation != nil else { return }
                    // RFC 6749 §10.12: Validate state parameter to prevent CSRF
                    guard state == expectedState else {
                        self.timeoutTask?.cancel()
                        self.continuation?.resume(throwing: OAuthError.stateMismatch)
                        self.continuation = nil
                        return
                    }
                    self.timeoutTask?.cancel()
                    self.continuation?.resume(returning: code)
                    self.continuation = nil
                }
            }
            // 5-minute timeout — properly cancellable
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.server?.stop()
                self?.server = nil
                self?.continuation?.resume(throwing: OAuthError.timeout)
                self?.continuation = nil
            }
        }

        return try await exchangeCode(code, redirectURI: redirectURI)
    }

    private func exchangeCode(_ code: String, redirectURI: String) async throws -> OAuthCredentials {
        var req = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Use URLComponents for proper percent-encoding (prevents parameter injection)
        var formComps = URLComponents()
        formComps.queryItems = [
            URLQueryItem(name: "grant_type",    value: "authorization_code"),
            URLQueryItem(name: "code",          value: code),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "client_id",     value: OAuthConfig.clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "state",         value: oauthState),
        ]
        req.httpBody = formComps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Only expose structured error fields, never the raw body (may contain tokens)
            let msg = OAuthManager.sanitizedError(from: data)
            throw OAuthError.exchangeFailed(msg)
        }
        return try OAuthManager.parseTokenResponse(data)
    }

    // Only return safe error fields, never the raw response body
    static func sanitizedError(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = json["error"] as? String ?? "unknown_error"
            let desc  = json["error_description"] as? String
            if let desc { return "\(error): \(desc)" }
            return error
        }
        return "Token exchange failed"
    }

    private static func parseTokenResponse(_ data: Data) throws -> OAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw OAuthError.noAccessToken }

        let refresh = json["refresh_token"] as? String
        var expiresAt: Date?
        if let expiresIn = json["expires_in"] as? TimeInterval {
            expiresAt = Date().addingTimeInterval(expiresIn)
        }
        return OAuthCredentials(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }
}

enum OAuthError: LocalizedError {
    case invalidURL, noAccessToken, noRefreshToken
    case exchangeFailed(String)
    case timeout, cancelled, stateMismatch

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "Invalid authorization URL"
        case .noAccessToken:         return "No access token in response"
        case .noRefreshToken:        return "Session expired — please sign in again"
        case .exchangeFailed(let m): return "Login failed: \(m)"
        case .timeout:               return "Login timed out (5 min)"
        case .cancelled:             return "Login cancelled"
        case .stateMismatch:         return "Security error: OAuth state mismatch"
        }
    }
}
