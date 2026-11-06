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
