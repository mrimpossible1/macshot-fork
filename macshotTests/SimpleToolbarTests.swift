import Cocoa
import XCTest

/// MacShotty's short toolbar for ⌘⇧4 / ⌘⇧3.
final class SimpleToolbarTests: XCTestCase {

    private func button(_ action: ToolbarButtonAction) -> ToolbarButton {
        ToolbarButton(action: action, sfSymbol: "circle", tooltip: "x")
    }

    private func tools(_ buttons: [ToolbarButton]) -> [AnnotationTool] {
        buttons.compactMap { if case .tool(let t) = $0.action { return t }; return nil }
    }

    func testBottomKeepsTheSixToolsInOrderPlusColorAndUndo() {
        let full: [ToolbarButton] = [
            button(.tool(.pencil)), button(.tool(.line)), button(.tool(.arrow)), button(.tool(.rectangle)),
            button(.tool(.ellipse)), button(.tool(.marker)), button(.tool(.text)), button(.tool(.number)),
            button(.tool(.pixelate)), button(.tool(.loupe)), button(.color), button(.undo), button(.redo), button(.effects),
        ]
        let simple = ToolbarLayout.simpleBottomButtons(from: full, tools: OverlayView.simpleMarkupTools)
        XCTAssertEqual(tools(simple), [.arrow, .text, .rectangle, .marker, .pixelate, .number])
        XCTAssertEqual(simple.count, 8)
        XCTAssertTrue(simple.contains { if case .color = $0.action { return true }; return false })
        XCTAssertTrue(simple.contains { if case .undo = $0.action { return true }; return false })
        XCTAssertFalse(simple.contains { if case .redo = $0.action { return true }; return false })
    }

    func testBottomSkipsToolsTheUserTurnedOff() {
        let full: [ToolbarButton] = [button(.tool(.arrow)), button(.tool(.text)), button(.color), button(.undo)]
        XCTAssertEqual(tools(ToolbarLayout.simpleBottomButtons(from: full, tools: OverlayView.simpleMarkupTools)), [.arrow, .text])
    }

    func testRightKeepsCopyLinkSaveAndAllTools() {
        var full: [ToolbarButton] = [button(.cancel), button(.moveSelection), button(.detach), button(.copy), button(.save),
                                     button(.share), button(.pin), button(.ocr), button(.scrollCapture), button(.record)]
        #if !OFFLINE
        full.append(button(.upload))
        #endif
        let simple = ToolbarLayout.simpleRightButtons(from: full)
        let kinds: [String] = simple.map {
            switch $0.action {
            case .cancel: return "cancel"
            case .copy: return "copy"
            case .save: return "save"
            case .upload: return "link"
            case .detach: return "allTools"
            default: return "other"
            }
        }
        #if OFFLINE
        XCTAssertEqual(kinds, ["cancel", "copy", "save", "allTools"])
        #else
        XCTAssertEqual(kinds, ["cancel", "copy", "save", "link", "allTools"])
        #endif
    }

    func testAllToolsHotkeyDefaultsToCommandShiftX() {
        let slot = HotkeyManager.HotkeySlot.captureAreaAllTools
        XCTAssertEqual(slot.defaultKeyCode, 7)  // kVK_ANSI_X
        XCTAssertNotEqual(slot.defaultModifiers, 0)
        XCTAssertNotEqual(slot.defaultKeyCode, HotkeyManager.HotkeySlot.captureArea.defaultKeyCode)
    }
}
