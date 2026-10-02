// Renders the Openflow app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS squircle-ish plate with margin.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
ctx.saveGState()
path.addClip()
let colors = [NSColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1).cgColor,
              NSColor(red: 0.16, green: 0.13, blue: 0.34, alpha: 1).cgColor,
              NSColor(red: 0.27, green: 0.38, blue: 0.78, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 824, y: 924), options: [])
// soft glow
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(white: 1, alpha: 0.16).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
ctx.restoreGState()

// Waveform bars.
let heights: [CGFloat] = [120, 230, 360, 470, 380, 250, 150]
let barW: CGFloat = 52, gap: CGFloat = 30
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = 512 - total / 2
for h in heights {
    let r = NSRect(x: x, y: 512 - h / 2, width: barW, height: h)
    let bar = NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2)
    NSColor(white: 1, alpha: 0.96).setFill()
    bar.fill()
    x += barW + gap
}
// subtle rim
NSColor(white: 1, alpha: 0.12).setStroke()
path.lineWidth = 4
path.stroke()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
