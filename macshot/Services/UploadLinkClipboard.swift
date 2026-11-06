#if !OFFLINE
import Cocoa

/// Puts an upload's link on the clipboard in the format chosen in
/// Settings → Uploads: the bare URL, a Markdown link, or a rich link that
/// pastes into Slack, Notion, Google Docs or Mail as the file's name.
enum UploadLinkClipboard {
    enum Format: String, CaseIterable {
        case url, markdown, rich
    }

    static let defaultsKey = "uploadLinkFormat"

    static var format: Format {
        Format(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .url
    }

    /// The link text people see: the file name from the link, without the
    /// extension. Dropbox "no link" page URLs carry it in `?preview=`.
    nonisolated static func displayName(forLink link: String) -> String {
        guard let components = URLComponents(string: link) else { return "Screenshot" }
        let file = components.queryItems?.first(where: { $0.name == "preview" })?.value
            ?? (components.path as NSString).lastPathComponent
        let name = (file as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? "Screenshot" : name
    }

    nonisolated static func markdown(link: String, name: String) -> String {
        let text = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let target = link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(text)](\(target))"
    }

    nonisolated static func html(link: String, name: String) -> String {
        "<a href=\"\(escape(link))\">\(escape(name))</a>"
    }

    nonisolated private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func copy(_ link: String, pasteboard: NSPasteboard = .general) {
        let name = displayName(forLink: link)
        pasteboard.clearContents()
        switch format {
        case .url:
            pasteboard.setString(link, forType: .string)
        case .markdown:
            pasteboard.setString(markdown(link: link, name: name), forType: .string)
        case .rich:
            // Rich editors take the HTML anchor; plain-text fields get the URL.
            pasteboard.declareTypes([.html, .string], owner: nil)
            pasteboard.setString(html(link: link, name: name), forType: .html)
            pasteboard.setString(link, forType: .string)
        }
    }
}
#endif
