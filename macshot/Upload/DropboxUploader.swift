#if !OFFLINE
import Cocoa
import Security
import CryptoKit
import AuthenticationServices

/// Uploads captures into a Dropbox folder (default `/Share`) and returns a
/// shared link. Sign-in uses OAuth2 PKCE with the user's own Dropbox app key,
/// so no client secret ships in the binary.
///
/// Dropbox API reference:
/// https://www.dropbox.com/developers/documentation/http/documentation
final class DropboxUploader: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DropboxUploader()

    /// Link visibility for uploaded files. `team` only works on Dropbox
    /// Business accounts; `none` saves the file without creating a link.
    enum LinkAudience: String, CaseIterable {
        case publicLink = "public"
        case team = "team"
        case none = "none"
    }

    nonisolated static let defaultFolder = "/Share"
    /// Dropbox caps a single-request upload at 150 MB. Stay under it and use an
    /// upload session above this size.
    nonisolated static let singleUploadLimit = 140 * 1024 * 1024
    nonisolated static let sessionChunkSize = 32 * 1024 * 1024
    private let scopes = "account_info.read files.content.write files.content.read sharing.write sharing.read"
    private let authorizeURL = "https://www.dropbox.com/oauth2/authorize"
    private let tokenURL = "https://api.dropboxapi.com/oauth2/token"
    private let apiURL = "https://api.dropboxapi.com/2"
    private let contentURL = "https://content.dropboxapi.com/2"

    private let session: URLSession
    private let tokenFileOverride: URL?
    private let defaults: UserDefaults
    private let retryDelay: UInt64
    private var authGeneration = UUID()
    private var tokenRefresh: (id: UUID, task: Task<String, Error>)?
    private var authSession: ASWebAuthenticationSession?
    private weak var presentationWindow: NSWindow?

    init(session: URLSession? = nil, tokenFileURL: URL? = nil,
         defaults: UserDefaults = .standard, retryDelayNanoseconds: UInt64 = 2_000_000_000) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        self.session = session ?? URLSession(configuration: config)
        self.tokenFileOverride = tokenFileURL
        self.defaults = defaults
        self.retryDelay = retryDelayNanoseconds
        super.init()
    }

    // MARK: - Settings

    /// The App key from the user's app at https://www.dropbox.com/developers/apps
    var appKey: String {
        defaults.string(forKey: "dropboxAppKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    var isSignedIn: Bool { loadRefreshToken() != nil }
    var accountName: String? { defaults.string(forKey: "dropboxAccountName") }

    var folderPath: String { Self.normalizedFolder(defaults.string(forKey: "dropboxFolder")) }

    var linkAudience: LinkAudience {
        LinkAudience(rawValue: defaults.string(forKey: "dropboxLinkAudience") ?? "") ?? .publicLink
    }

    /// When on, image links end in `raw=1` so they open as the bare image
    /// (embeddable, previews in Slack/iMessage) instead of the Dropbox viewer.
    var directLinks: Bool { defaults.bool(forKey: "dropboxDirectLinks") }

    /// `"Share"`, `"/Share/"`, `" /Share "` → `"/Share"`. Empty → the default.
    nonisolated static func normalizedFolder(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        return parts.isEmpty ? defaultFolder : "/" + parts.joined(separator: "/")
    }

    nonisolated static func destinationPath(folder: String, filename: String) -> String {
        let name = filename.replacingOccurrences(of: "/", with: "-")
        return normalizedFolder(folder) + "/" + name
    }

    /// Dropbox share links end in `dl=0` (viewer page). `raw=1` serves the
    /// file itself. Other query items (such as `rlkey`) must be kept.
    nonisolated static func directLink(from link: String) -> String {
        guard var components = URLComponents(string: link) else { return link }
        var items = (components.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }
        items.append(URLQueryItem(name: "raw", value: "1"))
        components.queryItems = items
        return components.url?.absoluteString ?? link
    }

    /// The owner-only dropbox.com page for a file: its folder, previewing it.
    nonisolated static func webURL(forPath path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var components = URLComponents(string: "https://www.dropbox.com")!
        components.path = "/home" + (folder == "/" ? "" : folder)
        components.queryItems = [URLQueryItem(name: "preview", value: name)]
        return components.url?.absoluteString ?? "https://www.dropbox.com/home"
    }

    /// The `Dropbox-API-Arg` header must be ASCII. Non-ASCII characters (an
    /// accented window title in the filename, say) are escaped as `\uXXXX`.
    nonisolated static func apiArgHeader(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw error("Could not encode request") }
        var out = ""
        for unit in json.utf16 {
            if unit < 0x7F { out.unicodeScalars.append(Unicode.Scalar(unit)!) }
            else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }

    // MARK: - Sign in

    private var redirectScheme: String { "db-\(appKey)" }
    private var redirectURI: String { "\(redirectScheme)://2/token" }

    func signIn(from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard !appKey.isEmpty else { completion(false); return }
        authGeneration = UUID()
        let generation = authGeneration
        authSession?.cancel()
        tokenRefresh?.task.cancel()
        tokenRefresh = nil
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let key = appKey
        let redirect = redirectURI

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: key),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: scopes),
        ]
        guard let authURL = components.url else { completion(false); return }

        presentationWindow = window
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self, self.authGeneration == generation else { completion(false); return }
                self.authSession = nil
                guard let callbackURL, error == nil,
                      let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
                    completion(false)
                    return
                }
                self.exchangeCode(code, codeVerifier: codeVerifier, appKey: key, redirectURI: redirect, completion: completion)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() { authSession = nil; completion(false) }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func signOut() {
        authGeneration = UUID()
        authSession?.cancel()
        authSession = nil
        tokenRefresh?.task.cancel()
        tokenRefresh = nil
        deleteTokens()
        defaults.removeObject(forKey: "dropboxAccountName")
    }

    private func checkAccount(_ generation: UUID) throws {
        guard generation == authGeneration else { throw Self.error("Account changed during upload") }
    }

    private func tokenRequest(_ values: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = UploadTransport.formBody(values)
        return request
    }

    private func exchangeCode(_ code: String, codeVerifier: String, appKey: String, redirectURI: String,
                              completion: @escaping (Bool) -> Void) {
        let generation = authGeneration
        let request = tokenRequest(["code": code, "client_id": appKey, "redirect_uri": redirectURI,
                                    "grant_type": "authorization_code", "code_verifier": codeVerifier])
        Task { [weak self] in
            guard let self else { completion(false); return }
            do {
                let json = try await jsonResponse(request)
                try checkAccount(generation)
                guard let access = json["access_token"] as? String,
                      let refresh = json["refresh_token"] as? String ?? loadRefreshToken() else {
                    throw Self.error("Invalid authentication response")
                }
                let expiry = Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 14400) - 60))
                saveToken(accessToken: access, refreshToken: refresh, expiry: expiry.timeIntervalSince1970)
                guard loadAccessToken() == access else { throw Self.error("Could not save authentication") }
                fetchAccountName(accessToken: access)
                NSApp.activate(ignoringOtherApps: true)
                completion(true)
            } catch { completion(false) }
        }
    }

    private func validToken(forceRefresh: Bool = false) async throws -> String {
        let generation = authGeneration
        if !forceRefresh, let expiry = loadExpiry(), Date().timeIntervalSince1970 < expiry,
           let token = loadAccessToken() { return token }
        if let pending = tokenRefresh { return try await pending.task.value }
        guard let refresh = loadRefreshToken() else { throw Self.error("Dropbox not signed in") }
        let key = appKey
        guard !key.isEmpty else { throw Self.error("Dropbox app key missing. Check Settings.") }
        let id = UUID()
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let json = try await jsonResponse(tokenRequest(["refresh_token": refresh, "client_id": key,
                                                           "grant_type": "refresh_token"]))
            try checkAccount(generation)
            guard let access = json["access_token"] as? String else { throw Self.error("Dropbox sign-in expired") }
            let expiry = Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 14400) - 60))
            saveToken(accessToken: access, refreshToken: refresh, expiry: expiry.timeIntervalSince1970)
            guard loadAccessToken() == access else { throw Self.error("Could not save authentication") }
            return access
        }
        tokenRefresh = (id, task)
        defer { if tokenRefresh?.id == id { tokenRefresh = nil } }
        return try await task.value
    }

    func fetchAccountName(accessToken: String? = nil, completion: (() -> Void)? = nil) {
        let generation = authGeneration
        Task { [weak self] in
            guard let self else { completion?(); return }
            let token: String
            if let accessToken { token = accessToken }
            else if let refreshed = try? await validToken() { token = refreshed }
            else { completion?(); return }
            var request = URLRequest(url: URL(string: apiURL + "/users/get_current_account")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json = try? await jsonResponse(request), generation == authGeneration {
                let email = json["email"] as? String
                let name = (json["name"] as? [String: Any])?["display_name"] as? String
                if let label = email ?? name { defaults.set(label, forKey: "dropboxAccountName") }
            }
            completion?()
        }
    }

    // MARK: - Upload

    func upload(payload: UploadPayload, filename: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        let generation = authGeneration
        let path = Self.destinationPath(folder: folderPath, filename: filename)
        let audience = linkAudience
        let direct = directLinks
        UploadJob.start(filename: filename, operation: { [weak self] in
            guard let self else { throw CancellationError() }
            let body = try await MediaExportIO.perform { try PreparedUploadBody(payload: payload) }
            try checkAccount(generation)
            _ = try await validToken()
            let stored: [String: Any]
            if body.byteCount <= Self.singleUploadLimit {
                stored = try await uploadSingle(body: body, path: path, generation: generation, progress: progress)
            } else {
                stored = try await uploadSession(body: body, path: path, generation: generation, progress: progress)
            }
            let storedPath = stored["path_display"] as? String ?? path
            guard audience != .none else {
                // No link wanted: hand back the file's page on dropbox.com
                // (only the owner can open it) so the toast still has a real URL.
                return Self.webURL(forPath: storedPath)
            }
            let fileRef = stored["id"] as? String ?? storedPath
            let link = try await sharedLink(for: fileRef, audience: audience, generation: generation)
            return direct ? Self.directLink(from: link) : link
        }, completion: completion)
    }

    /// `title` is a readable name from the screenshot's text (see
    /// `UploadPreparation`); without one the filename template is used.
    func uploadImage(_ image: NSImage, title: String? = nil, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let pixels = try HistoryImageSnapshot.Image(image)
            let template = defaults.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
            let base = title.map { ReadableCaptureName.filename(title: $0, date: Date()) } ?? FilenameFormatter.format(template: template)
            let name = base + ".png"
            upload(payload: .image(pixels), filename: name, progress: progress, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func uploadVideo(url: URL, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        upload(payload: .file(url), filename: url.lastPathComponent, progress: progress, completion: completion)
    }

    private func commitArg(path: String) -> [String: Any] {
        // `add` + `autorename` never overwrites: a name clash becomes "name (1).png".
        ["path": path, "mode": "add", "autorename": true, "mute": false, "strict_conflict": false]
    }

    private func contentRequest(_ endpoint: String, arg: Any, token: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: contentURL + endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(try Self.apiArgHeader(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        return request
    }

    private func uploadSingle(body: PreparedUploadBody, path: String, generation: UUID,
                              progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> [String: Any] {
        for attempt in 1...3 {
            try checkAccount(generation)
            var request = try contentRequest("/files/upload", arg: commitArg(path: path), token: try await validToken())
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            try checkAccount(generation)
            do {
                let (data, response) = try await UploadTransport.upload(session: session, request: request, body: body, progress: progress)
                try checkAccount(generation)
                if response.statusCode == 401, attempt < 3 { _ = try await validToken(forceRefresh: true); continue }
                if try await shouldRetry(response, data: data, attempt: attempt) { continue }
                return try Self.parseResponse(data, response: response)
            } catch let error as URLError where attempt < 3 && Self.isTransient(error) {
                try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
            }
        }
        throw Self.error("Upload could not be completed")
    }

    /// Large recordings go up in fixed chunks through an upload session.
    private func uploadSession(body: PreparedUploadBody, path: String, generation: UUID,
                               progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> [String: Any] {
        let total = body.byteCount
        let fileURL = body.url
        var offset = 0
        var sessionID: String?
        while true {
            let start = offset
            let chunk = try await MediaExportIO.perform { () throws -> Data in
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                return try handle.read(upToCount: Self.sessionChunkSize) ?? Data()
            }
            let isLast = offset + chunk.count >= total
            let endpoint: String
            let arg: [String: Any]
            if let sessionID {
                let cursor: [String: Any] = ["session_id": sessionID, "offset": offset]
                if isLast {
                    endpoint = "/files/upload_session/finish"
                    arg = ["cursor": cursor, "commit": commitArg(path: path)]
                } else {
                    endpoint = "/files/upload_session/append_v2"
                    arg = ["cursor": cursor, "close": false]
                }
            } else {
                endpoint = "/files/upload_session/start"
                arg = ["close": false]
            }
            let json = try await sendChunk(endpoint: endpoint, arg: arg, chunk: chunk, generation: generation)
            if sessionID == nil {
                guard let id = json["session_id"] as? String else { throw Self.error("Dropbox returned no upload session") }
                sessionID = id
                offset += chunk.count
                // A file exactly at a chunk boundary still needs a finish call.
                if offset >= total {
                    let cursor: [String: Any] = ["session_id": id, "offset": offset]
                    return try await sendChunk(endpoint: "/files/upload_session/finish",
                                               arg: ["cursor": cursor, "commit": commitArg(path: path)],
                                               chunk: Data(), generation: generation)
                }
            } else {
                offset += chunk.count
                if isLast { progress?(1); return json }
            }
            progress?(min(0.99, Double(offset) / Double(max(total, 1))))
        }
    }

    private func sendChunk(endpoint: String, arg: [String: Any], chunk: Data, generation: UUID) async throws -> [String: Any] {
        for attempt in 1...3 {
            try checkAccount(generation)
            let request = try contentRequest(endpoint, arg: arg, token: try await validToken())
            do {
                let (data, response) = try await session.upload(for: request, from: chunk)
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                try checkAccount(generation)
                if response.statusCode == 401, attempt < 3 { _ = try await validToken(forceRefresh: true); continue }
                if try await shouldRetry(response, data: data, attempt: attempt) { continue }
                // A retried append whose first attempt landed: Dropbox already
                // has these bytes and reports the offset it expects next.
                if response.statusCode == 409, attempt > 1,
                   let expected = (arg["cursor"] as? [String: Any])?["offset"] as? Int,
                   let correct = Self.correctOffset(in: data), correct == expected + chunk.count,
                   endpoint.hasSuffix("append_v2") {
                    return [:]
                }
                // append_v2 answers with an empty body ("null").
                if (200...299).contains(response.statusCode),
                   (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) is NSNull || data.isEmpty {
                    return [:]
                }
                return try Self.parseResponse(data, response: response)
            } catch let error as URLError where attempt < 3 && Self.isTransient(error) {
                try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
            }
        }
        throw Self.error("Upload could not be completed")
    }

    // MARK: - Shared links

    private func apiRequest(_ endpoint: String, body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: apiURL + endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func sharedLink(for fileRef: String, audience: LinkAudience, generation: UUID) async throws -> String {
        var settings: [String: Any]? = ["audience": audience.rawValue, "access": "viewer"]
        for attempt in 1...3 {
            try checkAccount(generation)
            var body: [String: Any] = ["path": fileRef]
            if let settings { body["settings"] = settings }
            let request = try await apiRequest("/sharing/create_shared_link_with_settings", body: body)
            let (data, raw) = try await session.data(for: request)
            guard let response = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try checkAccount(generation)
            if response.statusCode == 401, attempt < 3 { _ = try await validToken(forceRefresh: true); continue }
            if try await shouldRetry(response, data: data, attempt: attempt) { continue }
            if response.statusCode == 409 {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let summary = json?["error_summary"] as? String ?? ""
                if summary.hasPrefix("shared_link_already_exists") {
                    if let existing = Self.existingLinkURL(in: json) { return existing }
                    return try await listedLink(for: fileRef, generation: generation)
                }
                // A personal account can't make team-only links. Fall back to
                // the account's default link settings rather than failing.
                if summary.hasPrefix("settings_error") {
                    // Never fall back from team-only to the account default,
                    // which on a personal account is a public link.
                    if audience == .team { throw Self.error("Team-only links need a Dropbox Business account. Pick another link type in Settings.") }
                    if settings != nil { settings = nil; continue }
                }
            }
            let json = try Self.parseResponse(data, response: response)
            guard let url = json["url"] as? String else { throw Self.error("Dropbox returned no link") }
            return url
        }
        throw Self.error("Could not create a Dropbox link")
    }

    nonisolated static func correctOffset(in data: Data) -> Int? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let lookup = error?["incorrect_offset"] as? [String: Any] ?? error
        return lookup?["correct_offset"] as? Int
    }

    nonisolated static func existingLinkURL(in errorJSON: [String: Any]?) -> String? {
        let error = errorJSON?["error"] as? [String: Any]
        let exists = error?["shared_link_already_exists"] as? [String: Any]
        let metadata = exists?["metadata"] as? [String: Any]
        return metadata?["url"] as? String
    }

    private func listedLink(for fileRef: String, generation: UUID) async throws -> String {
        let request = try await apiRequest("/sharing/list_shared_links", body: ["path": fileRef, "direct_only": true])
        let json = try await jsonResponse(request)
        try checkAccount(generation)
        guard let links = json["links"] as? [[String: Any]], let url = links.first?["url"] as? String else {
            throw Self.error("Dropbox returned no link")
        }
        return url
    }

    // MARK: - HTTP helpers

    /// Retries rate limits (429, honoring Retry-After) and server errors.
    private func shouldRetry(_ response: HTTPURLResponse, data: Data, attempt: Int) async throws -> Bool {
        guard attempt < 3 else { return false }
        if response.statusCode == 429 {
            let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt * 2)
            try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 1), 30) * 1_000_000_000))
            return true
        }
        let summary = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error_summary"] as? String ?? ""
        if response.statusCode == 409, summary.contains("too_many_write_operations") {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            return true
        }
        if (500...599).contains(response.statusCode) {
            try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
            return true
        }
        return false
    }

    nonisolated private static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code)
    }

    private func jsonResponse(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Self.error("No response from server") }
        return try Self.parseResponse(data, response: response)
    }

    nonisolated static func parseResponse(_ data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(response.statusCode), let json else {
            let summary = json?["error_summary"] as? String
                ?? json?["error_description"] as? String
                ?? String(data: data.prefix(200), encoding: .utf8)
                ?? "Invalid server response"
            throw error("Dropbox: \(summary) (HTTP \(response.statusCode))")
        }
        return json
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Self.base64URL(Data(buffer))
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token storage (file-based, same approach as Google Drive)

    private struct TokenData: Codable {
        var accessToken: String?
        var refreshToken: String?
        var expiry: Double?
    }

    private var tokenFileURL: URL {
        if let tokenFileOverride { return tokenFileOverride }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.sw33tlie.macshot")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return dir.appendingPathComponent("dropbox_tokens.json")
    }

    private func loadTokens() -> TokenData {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let tokens = try? JSONDecoder().decode(TokenData.self, from: data) else { return TokenData() }
        return tokens
    }

    private func saveToken(accessToken: String, refreshToken: String, expiry: Double) {
        let tokens = TokenData(accessToken: accessToken, refreshToken: refreshToken, expiry: expiry)
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        do {
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
        } catch { /* The next token lookup reports a failed write. */ }
    }

    private func deleteTokens() { try? FileManager.default.removeItem(at: tokenFileURL) }
    private func loadAccessToken() -> String? { loadTokens().accessToken }
    private func loadRefreshToken() -> String? { loadTokens().refreshToken }
    private func loadExpiry() -> Double? { loadTokens().expiry }

    nonisolated static func error(_ msg: String) -> NSError {
        NSError(domain: "DropboxUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
#endif
