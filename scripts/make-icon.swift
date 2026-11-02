import AppKit
import Foundation

let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets"
let output = URL(fileURLWithPath: destination)
let iconset = output.appendingPathComponent("Citadel.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func image(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    guard let source = NSImage(contentsOf: output.appendingPathComponent("Citadel-lighthouse.png")) else {
        fatalError("Missing Assets/Citadel-lighthouse.png")
    }
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try image(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try image(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try image(1024).write(to: output.appendingPathComponent("Citadel.png"))
// Encode standard PNG-backed ICNS chunks directly, avoiding iconutil's XPC service.
func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
var chunks = Data()
for (type, size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
    let png = image(size)
    chunks.append(type.data(using: .ascii)!)
    chunks.append(bigEndian(UInt32(png.count + 8)))
    chunks.append(png)
}
var icns = "icns".data(using: .ascii)!
icns.append(bigEndian(UInt32(chunks.count + 8)))
icns.append(chunks)
try icns.write(to: output.appendingPathComponent("Citadel.icns"))
