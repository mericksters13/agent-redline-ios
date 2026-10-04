// Draws the hub app's icon into an .iconset folder for iconutil: a phone with one element marked
// in red and its note number, as Redline marks it on the device. The smallest sizes drop the
// phone's other rows and use heavier lines, so they stay readable.
//
//   swift scripts/hub-app-icon.swift <folder>.iconset
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1).cgColor
let white = NSColor.white.cgColor
func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { NSColor(white: white, alpha: alpha).cgColor }

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

/// The macOS icon shape on the standard 1024 point grid.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    for step in 0...720 {
        let angle = CGFloat(step) / 720 * 2 * .pi
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(cos(angle)), 0.4), cos(angle))
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(sin(angle)), 0.4), sin(angle))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// Draws the icon on the 1024 grid, top down, into a context scaled to `pixels`.
func draw(_ context: CGContext, pixels: CGFloat, small: Bool) {
    let scale = pixels / 1024
    func fill(_ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }
    func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokePath()
    }

    // The black body, with the grid's drop shadow and a faint edge.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: gray(0, 0.32))
    fill(squircle(body), gray(0))
    context.restoreGState()
    context.saveGState()
    context.addPath(squircle(body))
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [gray(0.17), gray(0.02)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    context.restoreGState()
    stroke(squircle(body.insetBy(dx: 2, dy: 2)), gray(1, 0.14), 4)

    let badge: (center: CGPoint, radius: CGFloat)
    if small {
        stroke(rounded(CGRect(x: 322, y: 196, width: 380, height: 632), 96), white, 46)
        fill(rounded(CGRect(x: 392, y: 448, width: 240, height: 112), 24), white)
        stroke(rounded(CGRect(x: 364, y: 420, width: 296, height: 168), 40), red, 30)
        badge = (CGPoint(x: 660, y: 420), 76)
    } else {
        stroke(rounded(CGRect(x: 332, y: 206, width: 360, height: 612), 82), white, 26)
        fill(rounded(CGRect(x: 464, y: 248, width: 96, height: 28), 14), white)
        fill(rounded(CGRect(x: 382, y: 326, width: 260, height: 58), 16), gray(1, 0.3))
        fill(rounded(CGRect(x: 382, y: 448, width: 260, height: 92), 20), white)
        stroke(rounded(CGRect(x: 362, y: 428, width: 300, height: 132), 30), red, 16)
        fill(rounded(CGRect(x: 382, y: 606, width: 260, height: 58), 16), gray(1, 0.3))
        fill(rounded(CGRect(x: 382, y: 700, width: 170, height: 40), 14), gray(1, 0.3))
        badge = (CGPoint(x: 662, y: 428), 54)
    }

    // The note number, ringed in the body's color so it sits on top of the phone's edge.
    fill(circle(badge.center, badge.radius * 1.26), gray(0.1))
    fill(circle(badge.center, badge.radius), red)
    guard !small else { return }
    let base = NSFont.systemFont(ofSize: badge.radius * 1.3, weight: .bold)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: base.pointSize) ?? base
    let number = NSAttributedString(string: "1", attributes: [.font: font, .foregroundColor: NSColor.white])
    number.draw(at: CGPoint(x: badge.center.x - number.size().width / 2, y: badge.center.y + font.capHeight / 2 - font.ascender))
}

let sizes: [(name: String, pixels: Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for size in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.pixels, pixelsHigh: size.pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(size.pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(size.pixels))
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context, pixels: CGFloat(size.pixels), small: size.pixels <= 64)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appending(path: "icon_\(size.name).png"))
}
