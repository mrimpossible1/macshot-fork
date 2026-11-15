import Foundation

/// A named video look (frame, pointer, zoom, keystrokes, camera, captions)
/// that can be saved once and applied to any recording, like Screen Studio
/// presets. Decodes leniently so a preset written by an older build still loads.
nonisolated struct VideoLookPreset: Codable, Equatable, Sendable {
    var name: String
    var look: VideoLook

    init(name: String, look: VideoLook) {
        self.name = name
        self.look = look
    }

    private enum CodingKeys: String, CodingKey { case name, look }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decode(.name, or: "")
        look = c.decode(.look, or: VideoLook())
    }
}

/// Saved presets, kept in UserDefaults in the order they were created.
enum VideoLookPresets {
    static let defaultsKey = "videoLookPresets"
    static let maxNameLength = 60

    static func all(defaults: UserDefaults = .standard) -> [VideoLookPreset] {
        guard let data = defaults.data(forKey: defaultsKey),
              let presets = LenientArrayDecoder.decode(VideoLookPreset.self, from: data) else { return [] }
        return presets.filter { !$0.name.isEmpty }
    }

    /// Trims whitespace and caps the length. Returns nil for an empty name.
    static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Saves `look` under `name`, replacing a preset with the same name
    /// (case-insensitive) in place so its position in the list is kept.
    @discardableResult
    static func save(name raw: String, look: VideoLook, defaults: UserDefaults = .standard) -> Bool {
        guard let name = cleanName(raw) else { return false }
        var presets = all(defaults: defaults)
        let preset = VideoLookPreset(name: name, look: look)
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        return store(presets, defaults: defaults)
    }

    @discardableResult
    static func delete(name: String, defaults: UserDefaults = .standard) -> Bool {
        let presets = all(defaults: defaults).filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        return store(presets, defaults: defaults)
    }

    private static func store(_ presets: [VideoLookPreset], defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(presets) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }
}
