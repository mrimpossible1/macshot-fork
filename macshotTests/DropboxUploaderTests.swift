#if !OFFLINE
import Cocoa
import XCTest

private final class DropboxFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: Data }
    nonisolated static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> Reply)?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}
    nonisolated override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            guard let handler else { throw URLError(.unsupportedURL) }
            let result = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class DropboxUploaderTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "macshot-dropbox-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("fixture-app-key", forKey: "dropboxAppKey")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DropboxFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        DropboxFixtureProtocol.lock.lock(); DropboxFixtureProtocol.handler = nil; DropboxFixtureProtocol.lock.unlock()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func respond(_ handler: @escaping (URLRequest, Data) throws -> DropboxFixtureProtocol.Reply) {
        DropboxFixtureProtocol.lock.lock(); DropboxFixtureProtocol.handler = handler; DropboxFixtureProtocol.lock.unlock()
    }

    private func dropbox() throws -> DropboxUploader {
        let tokens = directory.appendingPathComponent("dropbox_tokens.json")
        try JSONSerialization.data(withJSONObject: ["accessToken": "fixture-access", "refreshToken": "fixture-refresh",
            "expiry": Date().timeIntervalSince1970 + 3600]).write(to: tokens)
        return DropboxUploader(session: session, tokenFileURL: tokens, defaults: defaults, retryDelayNanoseconds: 0)
    }

    private func upload(_ uploader: DropboxUploader, _ payload: UploadPayload, name: String) async throws -> String {
        defer { withExtendedLifetime(uploader) {} }
        return try await withCheckedThrowingContinuation { continuation in
            uploader.upload(payload: payload, filename: name) { continuation.resume(with: $0) }
        }
    }

    nonisolated private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: - Pure helpers

    func testFolderIsNormalizedAndDefaultsToShare() {
        XCTAssertEqual(DropboxUploader.normalizedFolder(nil), "/Share")
        XCTAssertEqual(DropboxUploader.normalizedFolder("   "), "/Share")
        XCTAssertEqual(DropboxUploader.normalizedFolder("Share"), "/Share")
        XCTAssertEqual(DropboxUploader.normalizedFolder(" /Share/Shots/ "), "/Share/Shots")
        XCTAssertEqual(DropboxUploader.normalizedFolder("/../Share/./x"), "/Share/x")
        XCTAssertEqual(DropboxUploader.destinationPath(folder: "Share", filename: "a/b.png"), "/Share/a-b.png")
    }

    func testDirectLinkSwapsDlForRawAndKeepsRlkey() {
        let link = "https://www.dropbox.com/scl/fi/abc/shot.png?rlkey=xyz&dl=0"
        XCTAssertEqual(DropboxUploader.directLink(from: link), "https://www.dropbox.com/scl/fi/abc/shot.png?rlkey=xyz&raw=1")
    }

    func testAPIArgHeaderIsASCII() throws {
        let header = try DropboxUploader.apiArgHeader(["path": "/Share/Café 📸.png"])
        XCTAssertTrue(header.allSatisfy { $0.isASCII })
        let decoded = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["path"], "/Share/Café 📸.png")
    }

    func testExistingLinkIsReadFromConflictError() {
        let error: [String: Any] = ["error_summary": "shared_link_already_exists/metadata/..",
            "error": [".tag": "shared_link_already_exists", "shared_link_already_exists": ["metadata": ["url": "https://db.tt/existing"]]]]
        XCTAssertEqual(DropboxUploader.existingLinkURL(in: error), "https://db.tt/existing")
        XCTAssertNil(DropboxUploader.existingLinkURL(in: ["error_summary": "other"]))
    }

    // MARK: - Request flow (local fixtures, no live Dropbox)

    func testUploadsToShareFolderThenCreatesPublicLink() async throws {
        let data = Data("screenshot bytes".utf8)
        let uploader = try dropbox()
        respond { request, body in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            switch request.url?.path {
            case "/2/files/upload":
                XCTAssertEqual(body, data)
                let arg = try JSONSerialization.jsonObject(with: Data((request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "").utf8)) as? [String: Any]
                XCTAssertEqual(arg?["path"] as? String, "/Share/shot.png")
                XCTAssertEqual(arg?["mode"] as? String, "add")
                XCTAssertEqual(arg?["autorename"] as? Bool, true)
                return .init(status: 200, body: Self.json(["id": "id:abc", "path_display": "/Share/shot.png"]))
            case "/2/sharing/create_shared_link_with_settings":
                let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(sent?["path"] as? String, "id:abc")
                XCTAssertEqual((sent?["settings"] as? [String: Any])?["audience"] as? String, "public")
                XCTAssertNotNil((sent?["settings"] as? [String: Any])?["expires"], "links expire after 7 days by default")
                return .init(status: 200, body: Self.json(["url": "https://www.dropbox.com/scl/fi/abc/shot.png?rlkey=k&dl=0"]))
            default:
                XCTFail("unexpected request \(request.url?.absoluteString ?? "")")
                return .init(status: 500, body: Data())
            }
        }
        let link = try await upload(uploader, .data(data), name: "shot.png")
        XCTAssertEqual(link, "https://www.dropbox.com/scl/fi/abc/shot.png?rlkey=k&dl=0")
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testExistingLinkIsReusedAndDirectLinkApplied() async throws {
        defaults.set(true, forKey: "dropboxDirectLinks")
        let uploader = try dropbox()
        respond { request, _ in
            if request.url?.path == "/2/files/upload" {
                return .init(status: 200, body: Self.json(["id": "id:abc", "path_display": "/Share/shot.png"]))
            }
            return .init(status: 409, body: Self.json(["error_summary": "shared_link_already_exists/..",
                "error": ["shared_link_already_exists": ["metadata": ["url": "https://www.dropbox.com/scl/fi/abc/shot.png?dl=0"]]]]))
        }
        let link = try await upload(uploader, .data(Data([1, 2, 3])), name: "shot.png")
        XCTAssertEqual(link, "https://www.dropbox.com/scl/fi/abc/shot.png?raw=1")
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testNoLinkModeOnlyUploads() async throws {
        defaults.set("none", forKey: "dropboxLinkAudience")
        defaults.set("Clips", forKey: "dropboxFolder")
        let uploader = try dropbox()
        respond { request, _ in
            XCTAssertEqual(request.url?.path, "/2/files/upload")
            return .init(status: 200, body: Self.json(["id": "id:abc", "path_display": "/Clips/shot (1).png"]))
        }
        let result = try await upload(uploader, .data(Data([1])), name: "shot.png")
        XCTAssertEqual(result, "https://www.dropbox.com/home/Clips?preview=shot%20(1).png")
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testBuiltInAppKeyIsUsedUnlessOneIsSaved() throws {
        let uploader = try dropbox()
        XCTAssertEqual(uploader.appKey, "fixture-app-key")
        defaults.removeObject(forKey: "dropboxAppKey")
        XCTAssertEqual(uploader.appKey, DropboxUploader.builtInAppKey)
    }

    func testLinkSettingsCarryExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week = DropboxUploader.linkSettings(audience: .publicLink, expiryDays: 7, now: now)
        XCTAssertEqual(week["expires"] as? String, "2027-01-22T08:00:00Z")
        XCTAssertNil(DropboxUploader.linkSettings(audience: .publicLink, expiryDays: 0, now: now)["expires"])
    }

    func testExpiringLinkOnBasicPlanFailsInsteadOfMakingAPermanentOne() async throws {
        let uploader = try dropbox()
        var linkRequests = 0
        respond { request, _ in
            if request.url?.path == "/2/files/upload" {
                return .init(status: 200, body: Self.json(["id": "id:abc", "path_display": "/Share/shot.png"]))
            }
            linkRequests += 1
            return .init(status: 409, body: Self.json(["error_summary": "settings_error/not_authorized/.."]))
        }
        do {
            _ = try await upload(uploader, .data(Data([1])), name: "shot.png")
            XCTFail("should not fall back to a link that never expires")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Expiring links"))
        }
        XCTAssertEqual(linkRequests, 1)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testNeverExpiringStillFallsBackToAccountDefault() async throws {
        defaults.set(0, forKey: DropboxUploader.linkExpiryKey)
        let uploader = try dropbox()
        respond { request, body in
            if request.url?.path == "/2/files/upload" {
                return .init(status: 200, body: Self.json(["id": "id:abc", "path_display": "/Share/shot.png"]))
            }
            let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            if sent?["settings"] != nil {
                return .init(status: 409, body: Self.json(["error_summary": "settings_error/not_authorized/.."]))
            }
            return .init(status: 200, body: Self.json(["url": "https://www.dropbox.com/scl/fi/abc/shot.png?dl=0"]))
        }
        let link = try await upload(uploader, .data(Data([1])), name: "shot.png")
        XCTAssertEqual(link, "https://www.dropbox.com/scl/fi/abc/shot.png?dl=0")
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    // MARK: - Monthly archive

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var novemberSixth: Date { DropboxUploader.dropboxDate("2026-11-06T17:00:00Z")! }

    func testArchiveMovesOnlyEarlierMonthFilesAtTheTop() {
        let entries: [[String: Any]] = [
            [".tag": "file", "name": "Old.png", "path_display": "/Share/Old.png", "client_modified": "2026-10-31T23:59:00Z"],
            [".tag": "file", "name": "New.png", "path_display": "/Share/New.png", "client_modified": "2026-11-01T00:00:00Z"],
            [".tag": "folder", "name": "Archive", "path_display": "/Share/Archive"],
            [".tag": "file", "name": "Deep.png", "path_display": "/Share/Clients/Deep.png", "client_modified": "2026-01-01T00:00:00Z"],
            [".tag": "file", "name": "NoDate.png", "path_display": "/Share/NoDate.png", "server_modified": "2025-12-24T10:00:00Z"],
        ]
        let moves = DropboxUploader.archiveMoves(entries: entries, folder: "/Share", now: novemberSixth, calendar: utc)
        XCTAssertEqual(moves.map(\.from), ["/Share/Old.png", "/Share/NoDate.png"])
        XCTAssertEqual(moves.map(\.to), ["/Share/Archive/2026-10/Old.png", "/Share/Archive/2025-12/NoDate.png"])
    }

    func testArchiveRunsOncePerMonthAndRecordsIt() async throws {
        let uploader = try dropbox()
        let moved = NSMutableArray()
        respond { request, body in
            let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            switch request.url?.path {
            case "/2/files/list_folder":
                XCTAssertEqual(sent?["path"] as? String, "/Share")
                XCTAssertEqual(sent?["recursive"] as? Bool, false)
                return .init(status: 200, body: Self.json(["has_more": false, "cursor": "c", "entries": [
                    [".tag": "file", "name": "Old.png", "path_display": "/Share/Old.png", "client_modified": "2026-10-02T09:00:00Z"],
                    [".tag": "file", "name": "Now.png", "path_display": "/Share/Now.png", "client_modified": "2026-11-05T09:00:00Z"],
                ]]))
            case "/2/files/move_v2":
                moved.add("\(sent?["from_path"] as? String ?? "")>\(sent?["to_path"] as? String ?? "")")
                XCTAssertEqual(sent?["autorename"] as? Bool, true)
                return .init(status: 200, body: Self.json(["metadata": ["name": "Old.png"]]))
            default:
                XCTFail("unexpected request \(request.url?.absoluteString ?? "")")
                return .init(status: 500, body: Data())
            }
        }
        let count = try await withCheckedThrowingContinuation { continuation in
            uploader.archiveIfDue(now: novemberSixth, calendar: utc) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(moved as? [String], ["/Share/Old.png>/Share/Archive/2026-10/Old.png"])
        XCTAssertEqual(defaults.string(forKey: DropboxUploader.lastArchiveMonthKey), "2026-11")

        // Same month again: no requests at all.
        respond { request, _ in
            XCTFail("archive ran twice in one month: \(request.url?.path ?? "")")
            return .init(status: 500, body: Data())
        }
        let again = try await withCheckedThrowingContinuation { continuation in
            uploader.archiveIfDue(now: novemberSixth, calendar: utc) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(again, 0)
    }

    func testFailedArchiveIsRetriedLater() async throws {
        let uploader = try dropbox()
        respond { request, _ in
            if request.url?.path == "/2/files/list_folder" {
                return .init(status: 200, body: Self.json(["has_more": false, "entries": [
                    [".tag": "file", "name": "Old.png", "path_display": "/Share/Old.png", "client_modified": "2026-10-02T09:00:00Z"]]]))
            }
            return .init(status: 409, body: Self.json(["error_summary": "to/insufficient_space/"]))
        }
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                uploader.archiveIfDue(now: novemberSixth, calendar: utc) { continuation.resume(with: $0) }
            }
            XCTFail("archive should report the failed move")
        } catch {}
        XCTAssertNil(defaults.string(forKey: DropboxUploader.lastArchiveMonthKey))
    }

    func testHTTPErrorSurfacesDropboxSummary() async throws {
        let uploader = try dropbox()
        respond { _, _ in .init(status: 409, body: Self.json(["error_summary": "path/insufficient_space/"])) }
        do {
            _ = try await upload(uploader, .data(Data([1])), name: "shot.png")
            XCTFail("upload should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("insufficient_space"))
        }
        await MediaExportCoordinator.shared.waitUntilIdle()
    }
}
#endif
