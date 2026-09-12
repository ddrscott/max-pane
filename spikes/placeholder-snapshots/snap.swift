// Placeholder snapshot encoding: which format and resolution for an evicted
// web pane (PRD §10.3 / §14). No WebKit here — this measures the encode side
// only, against a synthetic page that has the things a real page has: large
// flat areas, text-like high-frequency detail, and a couple of images.
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// AppKit text drawing needs an initialised app, even offscreen.
_ = NSApplication.shared

func synthPage(width: CGFloat, height: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    let pw = Int(width * scale), ph = Int(height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // A header band and a hero image: the flat/gradient regions.
    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    NSRect(x: 0, y: height - 64, width: width, height: 64).fill()
    let grad = NSGradient(starting: NSColor.systemTeal, ending: NSColor.systemIndigo)!
    grad.draw(in: NSRect(x: 24, y: height - 340, width: width - 48, height: 240), angle: 35)

    // Body text: the high-frequency detail that actually decides the format.
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var y = height - 380.0
    var seed: UInt64 = 42
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 33) / Double(1 << 31) }
    while y > 20 {
        let chars = Int(30 + rnd() * 40)
        let line = String((0..<chars).map { _ in "abcdefghijklmnopqrstuvwxyz .,()-_/".randomElement()! })
        line.draw(at: NSPoint(x: 24, y: y), withAttributes: attrs)
        y -= 17
        if rnd() > 0.9 {
            NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
            NSRect(x: 24, y: y - 60, width: width - 48, height: 56).fill()
            y -= 70
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func encode(_ rep: NSBitmapImageRep, type: NSBitmapImageRep.FileType, quality: Double?) -> Data? {
    var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
    if let q = quality { props[.compressionFactor] = q }
    return rep.representation(using: type, properties: props)
}

func encodeHEIC(_ rep: NSBitmapImageRep, quality: Double) -> Data? {
    guard let cg = rep.cgImage else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

func time(_ n: Int, _ body: () -> Void) -> Double {
    body()
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<n { body() }
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n) / 1_000_000.0
}

let laneW: CGFloat = 560, laneH: CGFloat = 1000
print("Placeholder snapshot encoding — \(Int(laneW))x\(Int(laneH))pt lane\n")
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
print(pad("format", 12) + lpad("scale", 7) + lpad("bytes", 11) + lpad("enc ms", 9) + lpad("dec ms", 9))

struct Row { let name: String; let scale: CGFloat; let bytes: Int; let enc: Double; let dec: Double }
var rows: [Row] = []

for scale in [CGFloat(1.0), 2.0] {
    let rep = synthPage(width: laneW, height: laneH, scale: scale)
    let variants: [(String, () -> Data?)] = [
        ("png", { encode(rep, type: .png, quality: nil) }),
        ("jpeg q0.6", { encode(rep, type: .jpeg, quality: 0.6) }),
        ("jpeg q0.8", { encode(rep, type: .jpeg, quality: 0.8) }),
        ("heic q0.6", { encodeHEIC(rep, quality: 0.6) }),
        ("heic q0.8", { encodeHEIC(rep, quality: 0.8) }),
    ]
    for (name, make) in variants {
        guard let data = make() else { print("\(name): unsupported"); continue }
        let enc = time(10) { _ = make() }
        let dec = time(10) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            _ = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        rows.append(Row(name: name, scale: scale, bytes: data.count, enc: enc, dec: dec))
        print(pad(name, 12) + lpad(String(format: "%.0fx", scale), 7)
              + lpad(String(data.count), 11)
              + lpad(String(format: "%.2f", enc), 9)
              + lpad(String(format: "%.2f", dec), 9))
    }
}

print("\n130 evicted web lanes on disk:")
for r in rows {
    print("  " + pad(r.name, 12) + lpad(String(format: "@%.0fx", r.scale), 5)
          + lpad(String(format: "%.1f MB", Double(r.bytes) * 130 / 1_048_576), 12))
}
