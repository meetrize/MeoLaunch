import AppKit
import Foundation
import CoreGraphics

/// Extract the white cat silhouette from an orange (or any colored) icon into a
/// transparent PNG suitable for macOS menu-bar template images.
/// Usage: make_menubar_icon.swift <source.png> <out.png> [logicalPt]
/// Writes out.png at logicalPt*2 pixels (Retina) with black glyph + alpha.

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: make_menubar_icon.swift <source.png> <out.png> [logicalPt=18]\n", stderr)
    exit(1)
}

let srcPath = args[1]
let outPath = args[2]
let logicalPt = args.count >= 4 ? (CGFloat(Double(args[3]) ?? 18)) : 18
let pixelSize = Int(logicalPt * 2) // @2x

guard let srcImage = NSImage(contentsOfFile: srcPath) else {
    fputs("failed to load \(srcPath)\n", stderr)
    exit(1)
}

var srcRect = NSRect(origin: .zero, size: srcImage.size)
guard let srcCG = srcImage.cgImage(forProposedRect: &srcRect, context: nil, hints: nil) else {
    fputs("failed to get cgImage\n", stderr)
    exit(1)
}

let srcW = srcCG.width
let srcH = srcCG.height
let bytesPerRow = srcW * 4
var pixels = [UInt8](repeating: 0, count: srcH * bytesPerRow)
guard let readCtx = CGContext(
    data: &pixels,
    width: srcW,
    height: srcH,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}
readCtx.draw(srcCG, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

func isWhite(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Bool {
    // Keep near-white opaque pixels; drop orange/gradient and transparent.
    return a > 128 && r > 220 && g > 220 && b > 220
}

var minX = srcW, minY = srcH, maxX = 0, maxY = 0
var whiteCount = 0
for y in 0..<srcH {
    for x in 0..<srcW {
        let i = y * bytesPerRow + x * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2]), a = Int(pixels[i + 3])
        if isWhite(r, g, b, a) {
            whiteCount += 1
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}

guard whiteCount > 0 else {
    fputs("no white silhouette found\n", stderr)
    exit(1)
}

let bw = maxX - minX + 1
let bh = maxY - minY + 1
print("white=\(whiteCount) bbox=\(bw)x\(bh)")

var mask = [UInt8](repeating: 0, count: bw * bh * 4)
for y in 0..<bh {
    for x in 0..<bw {
        let si = ((minY + y) * bytesPerRow) + (minX + x) * 4
        let r = Int(pixels[si]), g = Int(pixels[si + 1]), b = Int(pixels[si + 2]), a = Int(pixels[si + 3])
        let di = (y * bw + x) * 4
        if isWhite(r, g, b, a) {
            // Template glyph: black + full alpha (system tints for light/dark bar)
            mask[di] = 0
            mask[di + 1] = 0
            mask[di + 2] = 0
            mask[di + 3] = 255
        }
    }
}

guard let maskCtx = CGContext(
    data: &mask,
    width: bw,
    height: bh,
    bitsPerComponent: 8,
    bytesPerRow: bw * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let catCG = maskCtx.makeImage() else {
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
var outPixels = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)
guard let outCtx = CGContext(
    data: &outPixels,
    width: pixelSize,
    height: pixelSize,
    bitsPerComponent: 8,
    bytesPerRow: pixelSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(1)
}
outCtx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
outCtx.interpolationQuality = .high

// Slight padding so glyph doesn't touch status-item edges
let pad = CGFloat(pixelSize) * 0.08
let avail = CGFloat(pixelSize) - pad * 2
let scale = min(avail / CGFloat(bw), avail / CGFloat(bh))
let dw = CGFloat(bw) * scale
let dh = CGFloat(bh) * scale
let dx = (CGFloat(pixelSize) - dw) / 2
let dy = (CGFloat(pixelSize) - dh) / 2
outCtx.draw(catCG, in: CGRect(x: dx, y: dy, width: dw, height: dh))

guard let outCG = outCtx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: outCG)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(pixelSize)x\(pixelSize) for \(Int(logicalPt))pt @2x)")
