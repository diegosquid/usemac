import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate-icon.swift <output-icns-path> [--source <master-png>] [--preview <png-path>] [--ext-dir <dir>]\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
var sourcePath: String?
var previewPath: String?
var extDirPath: String?

var argIdx = 2
while argIdx < CommandLine.arguments.count {
    let flag = CommandLine.arguments[argIdx]
    if flag == "--source", argIdx + 1 < CommandLine.arguments.count {
        sourcePath = CommandLine.arguments[argIdx + 1]
        argIdx += 2
    } else if flag == "--preview", argIdx + 1 < CommandLine.arguments.count {
        previewPath = CommandLine.arguments[argIdx + 1]
        argIdx += 2
    } else if flag == "--ext-dir", argIdx + 1 < CommandLine.arguments.count {
        extDirPath = CommandLine.arguments[argIdx + 1]
        argIdx += 2
    } else {
        argIdx += 1
    }
}

// Auto-discover Assets/usemac-icon-master.png relative to this script if --source omitted
if sourcePath == nil {
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidate = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Assets/usemac-icon-master.png")
    if FileManager.default.fileExists(atPath: candidate.path) {
        sourcePath = candidate.path
    }
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func loadMasterImage() -> CGImage? {
    guard let path = sourcePath,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let masterImage = loadMasterImage()

func renderIconPNGData(pixelSize: Int, macOSDockPadding: Bool = true) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let cg = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw NSError(domain: "UseMacIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
    }

    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    let scale = CGFloat(pixelSize) / 1024.0
    cg.scaleBy(x: scale, y: scale)

    // macOS Dock icon uses standard 824x824 squircle inside 1024x1024;
    // Chrome extension toolbar icons fill 960x960 so they read crisp at 16px-32px.
    let inset: CGFloat = macOSDockPadding ? 100 : 32
    let side: CGFloat = 1024 - (inset * 2)
    let cornerRadius: CGFloat = side * 0.224
    let bodyRect = CGRect(x: inset, y: inset, width: side, height: side)
    let squircle = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Light, tight drop shadow for Dock and Finder icons, close to the system's own icons.
    // A heavier one reads as a dark halo on light backgrounds (#62).
    if macOSDockPadding {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: color(0, 0, 0, 0.16))
        cg.addPath(squircle)
        cg.setFillColor(color(0.05, 0.05, 0.06, 1.0))
        cg.fillPath()
        cg.restoreGState()
    }

    // Clip to squircle and draw master artwork (or clean fallback vector)
    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()

    if let masterImage {
        // Draw slightly oversized (1.03x) inside squircle to keep edges ultra-clean
        let pad = side * 0.015
        let drawRect = bodyRect.insetBy(dx: -pad, dy: -pad)
        cg.draw(masterImage, in: drawRect)
    } else {
        // Fallback deep obsidian gradient + crisp U + arrow mark
        let bgColors = [
            color(0.145, 0.145, 0.160),
            color(0.075, 0.075, 0.085),
            color(0.045, 0.045, 0.052)
        ] as CFArray
        if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
            cg.drawLinearGradient(bgGrad, start: CGPoint(x: 512, y: bodyRect.maxY), end: CGPoint(x: 512, y: bodyRect.minY), options: [])
        }
        // Minimal white U stroke
        let uPath = CGMutablePath()
        uPath.move(to: CGPoint(x: 348, y: 676))
        uPath.addLine(to: CGPoint(x: 348, y: 452))
        uPath.addArc(center: CGPoint(x: 492, y: 452), radius: 144, startAngle: .pi, endAngle: 0, clockwise: false)
        uPath.addLine(to: CGPoint(x: 636, y: 520))
        cg.addPath(uPath)
        cg.setStrokeColor(color(0.98, 0.98, 1.0, 1.0))
        cg.setLineWidth(84)
        cg.setLineCap(.round)
        cg.strokePath()
    }

    // Delicate obsidian glass specular rim highlight
    cg.addPath(squircle)
    cg.setStrokeColor(color(1, 1, 1, macOSDockPadding ? 0.14 : 0.18))
    cg.setLineWidth(macOSDockPadding ? 5.5 : 10.0)
    cg.strokePath()
    cg.restoreGState()

    let mutableData = NSMutableData()
    guard let image = cg.makeImage(),
          let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "UseMacIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG encoder"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "UseMacIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
    }
    return mutableData as Data
}

func appendUInt32BigEndian(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let iconChunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512)
]

var pngCache: [Int: Data] = [:]
var body = Data()

for (osType, size) in iconChunks {
    let png: Data
    if let cached = pngCache[size] {
        png = cached
    } else {
        png = try renderIconPNGData(pixelSize: size, macOSDockPadding: true)
        pngCache[size] = png
    }

    guard let typeBytes = osType.data(using: .ascii), typeBytes.count == 4 else {
        continue
    }
    body.append(typeBytes)
    appendUInt32BigEndian(UInt32(8 + png.count), to: &body)
    body.append(png)
}

var icns = Data()
icns.append(contentsOf: "icns".utf8)
appendUInt32BigEndian(UInt32(8 + body.count), to: &icns)
icns.append(body)

try icns.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

if let previewPath {
    let previewData: Data
    if let cached = pngCache[512] {
        previewData = cached
    } else {
        previewData = try renderIconPNGData(pixelSize: 512, macOSDockPadding: true)
    }
    try previewData.write(to: URL(fileURLWithPath: previewPath), options: .atomic)
}

if let extDirPath {
    try FileManager.default.createDirectory(atPath: extDirPath, withIntermediateDirectories: true)
    for size in [16, 32, 48, 128] {
        let data = try renderIconPNGData(pixelSize: size, macOSDockPadding: false)
        let outURL = URL(fileURLWithPath: extDirPath).appendingPathComponent("icon\(size).png")
        try data.write(to: outURL, options: .atomic)
    }
}
