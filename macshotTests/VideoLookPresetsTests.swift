import XCTest

final class VideoLookPresetsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "macshot-presets-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSaveReplacesSameNameInPlaceAndKeepsOrder() {
        var framed = VideoLook()
        framed.frame.enabled = true
        framed.frame.padding = 0.2
        XCTAssertTrue(VideoLookPresets.save(name: "  Demo  ", look: VideoLook(), defaults: defaults))
        XCTAssertTrue(VideoLookPresets.save(name: "Social", look: VideoLook(), defaults: defaults))
        XCTAssertTrue(VideoLookPresets.save(name: "demo", look: framed, defaults: defaults))

        let presets = VideoLookPresets.all(defaults: defaults)
        XCTAssertEqual(presets.map(\.name), ["demo", "Social"])
        XCTAssertEqual(presets.first?.look, framed)
    }

    func testEmptyNamesAreRejectedAndLongNamesCapped() {
        XCTAssertFalse(VideoLookPresets.save(name: "   ", look: VideoLook(), defaults: defaults))
        XCTAssertTrue(VideoLookPresets.all(defaults: defaults).isEmpty)
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(VideoLookPresets.cleanName(long)?.count, VideoLookPresets.maxNameLength)
    }

    func testDeleteRemovesOnlyThatPreset() {
        VideoLookPresets.save(name: "A", look: VideoLook(), defaults: defaults)
        VideoLookPresets.save(name: "B", look: VideoLook(), defaults: defaults)
        VideoLookPresets.delete(name: "a", defaults: defaults)
        XCTAssertEqual(VideoLookPresets.all(defaults: defaults).map(\.name), ["B"])
    }

    func testCorruptStorageLoadsAsEmpty() {
        defaults.set(Data("not json".utf8), forKey: VideoLookPresets.defaultsKey)
        XCTAssertTrue(VideoLookPresets.all(defaults: defaults).isEmpty)
    }
}
