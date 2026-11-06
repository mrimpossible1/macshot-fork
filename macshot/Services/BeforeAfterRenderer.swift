import Cocoa
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Before/after from two captures: one side-by-side image, or a looping GIF
/// that fades from one to the other. Each shot gets a small "Before" /
/// "After" label in its top-left corner.
enum BeforeAfterRenderer {
    struct Layout: Equatable {
        let canvas: CGSize
        let before: CGRect
        let after: CGRect
    }

    nonisolated static var background: CGColor { CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) }

    /// `size` scaled down (never up) so its longest side is at most `maxSide`.
    nonisolated static func fitted(_ size: CGSize, maxSide: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return size }
        let scale = maxSide / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Wide shots stack top/bottom; tall or square ones sit left/right.
    nonisolated static func stacksVertically(_ a: CGSize, _ b: CGSize) -> Bool {
        let aspect = (a.width / max(a.height, 1) + b.width / max(b.height, 1)) / 2
        return aspect > 1.6
    }

    /// Both shots at the same height (side by side) or width (stacked),
    /// matched to the smaller one so neither is blown up. CG coordinates:
    /// origin bottom-left, so "before" is the left or the top one.
    nonisolated static func sideBySideLayout(before: CGSize, after: CGSize, maxSide: CGFloat = 2000,
                                             padding: CGFloat = 32, gap: CGFloat = 24) -> Layout {
        let b0 = fitted(before, maxSide: maxSide), a0 = fitted(after, maxSide: maxSide)
        func scaled(_ size: CGSize, to target: CGFloat, byWidth: Bool) -> CGSize {
            let factor = target / max(byWidth ? size.width : size.height, 1)
            return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        }
        if stacksVertically(b0, a0) {
            let width = min(b0.width, a0.width)
            let b = scaled(b0, to: width, byWidth: true), a = scaled(a0, to: width, byWidth: true)
            return Layout(canvas: CGSize(width: width + padding * 2, height: b.height + a.height + gap + padding * 2),
                          before: CGRect(x: padding, y: padding + a.height + gap, width: b.width, height: b.height),
                          after: CGRect(x: padding, y: padding, width: a.width, height: a.height))
        }
        let height = min(b0.height, a0.height)
        let b = scaled(b0, to: height, byWidth: false), a = scaled(a0, to: height, byWidth: false)
        return Layout(canvas: CGSize(width: b.width + a.width + gap + padding * 2, height: height + padding * 2),
                      before: CGRect(x: padding, y: padding, width: b.width, height: b.height),
                      after: CGRect(x: padding + b.width + gap, y: padding, width: a.width, height: a.height))
    }

    /// One canvas both GIF frames fit into.
    nonisolated static func gifCanvas(before: CGSize, after: CGSize, maxSide: CGFloat = 1400) -> CGSize {
        let b = fitted(before, maxSide: maxSide), a = fitted(after, maxSide: maxSide)
        return CGSize(width: max(b.width, a.width), height: max(b.height, a.height))
    }

    /// `size` scaled to fit `canvas`, centered.
    nonisolated static func aspectFit(_ size: CGSize, in canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / max(size.width, 1), canvas.height / max(size.height, 1))
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)
    }

    nonisolated static func sideBySide(before: CGImage, after: CGImage) -> CGImage? {
        let layout = sideBySideLayout(before: CGSize(width: before.width, height: before.height),
                                      after: CGSize(width: after.width, height: after.height))
        guard let context = makeContext(layout.canvas) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: layout.canvas))
        context.interpolationQuality = .high
        context.draw(before, in: layout.before)
        context.draw(after, in: layout.after)
        drawLabel("Before", in: layout.before, context: context)
        drawLabel("After", in: layout.after, context: context)
        return context.makeImage()
    }

    /// Before (held), fade to after, after (held), fade back; loops forever.
    nonisolated static func gif(before: CGImage, after: CGImage, hold: Double = 1.6,
                                fadeFrames: Int = 6, fadeStep: Double = 0.06) -> Data? {
        let canvas = gifCanvas(before: CGSize(width: before.width, height: before.height),
                               after: CGSize(width: after.width, height: after.height))
        let beforeRect = aspectFit(CGSize(width: before.width, height: before.height), in: canvas)
        let afterRect = aspectFit(CGSize(width: after.width, height: after.height), in: canvas)

        func frame(afterAlpha: CGFloat, label: String?) -> CGImage? {
            guard let context = makeContext(canvas) else { return nil }
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: canvas))
            context.interpolationQuality = .high
            if afterAlpha < 1 { context.draw(before, in: beforeRect) }
            if afterAlpha > 0 {
                context.setAlpha(afterAlpha)
                context.draw(after, in: afterRect)
                context.setAlpha(1)
            }
            if let label { drawLabel(label, in: afterAlpha > 0.5 ? afterRect : beforeRect, context: context) }
            return context.makeImage()
        }

        var frames: [(CGImage, Double)] = []
        guard let first = frame(afterAlpha: 0, label: "Before"), let last = frame(afterAlpha: 1, label: "After") else { return nil }
        let steps = (1...max(1, fadeFrames)).map { CGFloat($0) / CGFloat(fadeFrames + 1) }
        frames.append((first, hold))
        for t in steps { guard let f = frame(afterAlpha: t, label: nil) else { return nil }; frames.append((f, fadeStep)) }
        frames.append((last, hold))
        for t in steps.reversed() { guard let f = frame(afterAlpha: t, label: nil) else { return nil }; frames.append((f, fadeStep)) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for (image, delay) in frames {
            let properties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay,
                                                                        kCGImagePropertyGIFUnclampedDelayTime as String: delay]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated private static func makeContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// A white label on a dark rounded pill, inside the top-left corner of `rect`.
    nonisolated private static func drawLabel(_ text: String, in rect: CGRect, context: CGContext) {
        let fontSize = min(40, max(14, min(rect.width, rect.height) * 0.045))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padX = fontSize * 0.6, padY = fontSize * 0.35, inset = fontSize * 0.6
        let pill = CGRect(x: rect.minX + inset, y: rect.maxY - inset - bounds.height - padY * 2,
                          width: bounds.width + padX * 2, height: bounds.height + padY * 2)
        context.saveGState()
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: pill.minX + padX - bounds.minX, y: pill.minY + padY - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
